import CloudGatewayAppCore
import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation

@MainActor
public final class CloudGatewayMacController {
    public var onChange: (() -> Void)?
    public var onAuthenticationChange: (() -> Void)?
    private var observedAuthAccount: String?
    private var hasObservedAuthAccount = false

    private let auth: any CloudGatewayMacControllerAuthServicing
    private let inventory: any CloudGatewayMacInventoryServicing
    private let cache: CloudGatewayMacAccountCache
    private let profiles: any CloudGatewayMacProfileAdapter
    private let configs: CloudGatewayMacConfigCoordinator
    private let inventoryAuthorizationDidCommit: @MainActor () async -> Void
    private let cacheEvictionDidCommit: @MainActor () async -> Void
    private let now: () -> Date
    private let controllerId = UUID()
    private var setupState: CloudGatewayMacSetupState = .required
    private var browser: CloudGatewayMacBrowserAuthCoordinator!
    private var authRegistration: CloudGatewayAuthStateListenerRegistration?
    private var user: AuthenticatedUser?
    private var options: [CloudGatewayClientOption] = []
    private var removedIdentifiers: Set<String> = []
    private var installed: [CloudGatewayMacInstalledConfig] = []
    private var profileObservation = CloudGatewayMacProfileObservation()
    private var isOffline = false
    private var errorMessage: String?
    private var sessionEpoch: UInt64 = 0
    private var sessionFence = CloudGatewayMacSessionFence()
    private var lastSelectedIdentifier: String?
    private var selectedMode: CloudGatewayRoutingMode?
    private var cancellationTask: Task<Void, Never>?
    private var profileEpoch: UInt64 = 0
    private var profileTask: Task<Void, Never>?
    private var cancellationEpoch: UInt64 = 0
    private var isStarted = false
    private var isShuttingDown = false
    private var inventoryTask: Task<Void, Never>?
    private var inventoryEpoch: UInt64 = 0
    private let inventoryNow: () -> Duration
    private let inventoryJitter: () -> Double
    private var inventorySchedule: CloudGatewayMacInventorySchedule
    private var deferredInventoryRefresh = false
    private var deferredInventoryRefreshIsAutomatic = false
    private var automaticInventoryRefreshAllowed = true
    private var restorationTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var creationTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var isStopping = false
    private var managedReconnectIdentifier: String?
    private var managedStopTask: Task<Void, Never>?
    private var pendingLoginInventory: CloudGatewayMacSessionToken?
    private var retainedLogin: CloudGatewayMacLoginStatus?
    private var retainedLoginTimer: Task<Void, Never>?
    private var retainedLoginDeadline: Duration?
    private var retainedLoginTask: Task<Void, Never>?
    private let loginTimer: @Sendable (Duration) async throws -> Void
    private let loginNow: @Sendable () -> Duration
    private var inventoryCommitTask: Task<Void, Error>?
    private var hasAuthorizedInventory = false
    private var hasObservedProfiles = false
    private var accessResult: CloudGatewayMacAccessState?
    private var inventoryReadAt = Date.distantPast
    private var refreshResult: (epoch: UInt64, result: CloudGatewayMacRefreshResult)?
    private var profilesObservedAt: Date?

    public init(
        auth: any CloudGatewayMacControllerAuthServicing,
        deviceAuth: any CloudGatewayDeviceAuthServicing,
        inventory: any CloudGatewayMacInventoryServicing,
        profiles: any CloudGatewayMacProfileAdapter,
        cache: CloudGatewayMacAccountCache,
        configs: CloudGatewayMacConfigCoordinator,
        dashboardOrigin: URL,
        inventoryAuthorizationDidCommit: @escaping @MainActor () async -> Void = {},
        cacheEvictionDidCommit: @escaping @MainActor () async -> Void = {},
        now: @escaping () -> Date = Date.init,
        loginTimer: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        loginNow: (@Sendable () -> Duration)? = nil,
        loginSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        inventoryNow: (() -> Duration)? = nil,
        inventoryJitter: @escaping () -> Double = { Double.random(in: 0...1) }
    ) {
        self.auth = auth
        self.inventory = inventory
        self.profiles = profiles
        self.cache = cache
        self.configs = configs
        self.inventoryAuthorizationDidCommit = inventoryAuthorizationDidCommit
        self.cacheEvictionDidCommit = cacheEvictionDidCommit
        self.now = now
        self.loginTimer = loginTimer
        let loginClock = ContinuousClock()
        let loginOrigin = loginClock.now
        let monotonicNow: @Sendable () -> Duration = loginNow ?? { loginOrigin.duration(to: loginClock.now) }
        self.loginNow = monotonicNow
        let inventoryClock = inventoryNow ?? { monotonicNow() }
        self.inventoryNow = inventoryClock
        self.inventoryJitter = inventoryJitter
        inventorySchedule = .init(now: inventoryClock())
        browser = CloudGatewayMacBrowserAuthCoordinator(
            service: deviceAuth, auth: auth, dashboardOrigin: dashboardOrigin, openBrowser: { _ in },
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
                    accessResult = .denied
                    return false
                }
            }, now: monotonicNow, sleep: loginSleep, timer: loginTimer
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
        if inventoryTask != nil || deferredInventoryRefresh || inventoryCommitTask != nil || restorationTask != nil || commandTask != nil
            || creationTask != nil || stopTask != nil || cancellationTask != nil || managedStopTask != nil || profileTask != nil || auth.isCustomTokenSignInSettling {
            return true
        }
        switch browser.state {
        case .requestingCode, .waitingForApproval, .exchangingToken: return true
        default: return false
        }
    }

    public func snapshot() -> CloudGatewayMacControllerSnapshot {
        CloudGatewayMacControllerSnapshot(
            domain: CloudGatewayMacDomainSnapshot(
                accountId: user?.uid, hasRetainedSession: auth.currentUser != nil,
                accessAuthorized: user != nil, access: accessState,
                credentials: auth.currentUser != nil ? .available : .unknown,
                inventoryFreshness: inventoryTask != nil || deferredInventoryRefresh || inventoryCommitTask != nil ? .refreshing
                    : hasAuthorizedInventory ? (isOffline ? .cached : .current) : .unavailable,
                installedIdentifiers: installed.map(\.identifier),
                observedProfiles: profileObservation.profiles.map {
                    CloudGatewayMacObservedProfile(identifier: $0.identifier, status: $0.status, mode: $0.mode)
                },
                observationIsFresh: hasObservedProfiles && profileTask == nil && profileObservation.errorMessage == nil,
                profilesObservedAt: profilesObservedAt,
                commandInFlight: !canIssueLocalCommand, stopAllowed: canIssueStop,
                clients: clientMetadata, selectedMode: selectedMode
            ),
            lastSelectedIdentifier: lastSelectedIdentifier,
            browserState: visibleBrowserState, login: retainedLogin ?? browser.loginStatus, isRestoringSession: restorationTask != nil,
            isAuthSettling: auth.isCustomTokenSignInSettling,
            canCreateClient: canStartInventoryMutation, errorMessage: visibleErrorMessage
        )
    }

    public func menuWillOpen() {
        guard isStarted, !isShuttingDown else { return }
        refreshProfiles()
        recordUserActivity(refreshIfStale: true)
        notifyChange()
    }

    public func recordUserActivity(refreshIfStale: Bool) {
        guard isStarted, !isShuttingDown else { return }
        inventorySchedule.recordActivity(at: inventoryNow())
        guard refreshIfStale else { return }
        if user != nil {
            if inventorySchedule.isStale(at: inventoryNow()) || inventoryTask != nil {
                refreshInventory(force: false)
            }
        } else if auth.currentUser != nil { restoreSession() }
    }

    public func refreshInventoryIfDue() {
        guard isStarted, !isShuttingDown, inventoryTask == nil, inventoryCommitTask == nil,
              restorationTask == nil, commandTask == nil, creationTask == nil, stopTask == nil, cancellationTask == nil,
              automaticInventoryRefreshAllowed, inventorySchedule.isDue(at: inventoryNow()) else { return }
        switch browser.state {
        case .requestingCode, .waitingForApproval, .exchangingToken: return
        default: break
        }
        if user != nil { refreshInventory() }
        else if auth.currentUser != nil { restoreSession() }
    }

    public func setAutomaticInventoryRefreshAllowed(_ allowed: Bool, discardDeferred: Bool) {
        automaticInventoryRefreshAllowed = allowed
        if discardDeferred, deferredInventoryRefreshIsAutomatic {
            deferredInventoryRefresh = false
            deferredInventoryRefreshIsAutomatic = false
            notifyChange()
        }
        if allowed { resumeDeferredInventoryRefresh() }
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
        retainedLoginTimer?.cancel()
        retainedLoginTask?.cancel()
        browser.onChange = nil
        if isStarted {
            cancelPendingWork()
            browser.cancel()
        }
        managedStopTask?.cancel()
        managedStopTask = nil
        onChange = nil
        onAuthenticationChange = nil
    }

    private func authChanged(_ candidate: AuthenticatedUser?) {
        guard isStarted, !isShuttingDown else { return }
        if hasObservedAuthAccount, observedAuthAccount != candidate?.uid { onAuthenticationChange?() }
        observedAuthAccount = candidate?.uid
        hasObservedAuthAccount = true
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
                accessResult = nil
                errorMessage = nil
                refreshLoginInventory()
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
                accessResult = nil
                errorMessage = nil
                completeRetainedLoginAuthorization()
                refreshLoginInventory()
            } catch CloudGatewayMacInventoryError.offline {
                guard sessionEpoch == epoch, !Task.isCancelled,
                      auth.currentUser?.uid == candidate.uid else { return }
                inventorySchedule.complete(at: inventoryNow(), succeeded: false, jitter: inventoryJitter())
                let saved = try? await cache.load(accountId: candidate.uid)
                guard sessionEpoch == epoch, !Task.isCancelled,
                      auth.currentUser?.uid == candidate.uid else { return }
                do { try requireCurrent(epoch) } catch { return }
                if let saved, CloudGatewayMacOfflinePolicy.canUseCache(
                    after: CloudGatewayMacInventoryError.offline.cacheFailure, cache: saved
                ) {
                    user = candidate
                    sessionFence.changeAccount(to: candidate.uid)
                    accessResult = nil
                    installed = saved.configs
                    lastSelectedIdentifier = saved.selectedIdentifier
                    selectedMode = saved.selectedMode
                    isOffline = true
                    hasAuthorizedInventory = true
                    errorMessage = nil
                    completeRetainedLoginAuthorization()
                } else {
                    accessResult = .unreachable
                    errorMessage = "Unable to reach CloudGateway to restore this account"
                }
            } catch CloudGatewayMacInventoryError.accessDenied {
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                try? await cache.deny(accountId: candidate.uid)
                guard sessionEpoch == epoch, !Task.isCancelled,
                      auth.currentUser?.uid == candidate.uid else { return }
                try? auth.signOut()
                accessResult = .denied
                errorMessage = "Account access was denied. Sign in again after access is restored"
            } catch {
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                inventorySchedule.complete(at: inventoryNow(), succeeded: false, jitter: inventoryJitter())
                accessResult = .unreachable
                errorMessage = "Unable to restore your session. Refresh to try again"
            }
        }
        notifyChange()
    }

    private func refreshLoginInventory() {
        if isStopping { pendingLoginInventory = sessionFence.currentToken }
        else { refreshInventory() }
    }

    private func resumeLoginInventoryAfterStop() {
        guard let token = pendingLoginInventory else { return }
        pendingLoginInventory = nil
        guard sessionFence.isCurrent(token), user?.uid == token.accountId,
              auth.currentUser?.uid == token.accountId else { return }
        refreshInventory()
    }

    private func refreshInventory(force: Bool = true) {
        guard let account = user, inventoryTask == nil, !isShuttingDown else { return }
        if !force, !inventorySchedule.isStale(at: inventoryNow()) { return }
        guard commandTask == nil, creationTask == nil, stopTask == nil, cancellationTask == nil, inventoryCommitTask == nil,
              force || automaticInventoryRefreshAllowed else {
            deferredInventoryRefreshIsAutomatic = deferredInventoryRefresh ? deferredInventoryRefreshIsAutomatic && !force : !force
            deferredInventoryRefresh = true
            notifyChange()
            return
        }
        deferredInventoryRefresh = false
        deferredInventoryRefreshIsAutomatic = false
        inventoryEpoch &+= 1
        let refreshEpoch = inventoryEpoch
        let epoch = sessionEpoch
        let token = sessionFence.currentToken
        let pendingCancellation = cancellationTask
        inventoryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if sessionEpoch == epoch, inventoryEpoch == refreshEpoch {
                    if let result = refreshResult, result.epoch == refreshEpoch {
                        inventorySchedule.complete(at: inventoryNow(), succeeded: result.result == .refreshed, jitter: inventoryJitter())
                    }
                    inventoryTask = nil
                    notifyChange()
                }
            }
            do {
                await pendingCancellation?.value
                try requireCurrent(epoch, token: token)
                if options.isEmpty {
                    let saved = try? await cache.load(accountId: account.uid)
                    try requireCurrent(epoch, token: token)
                    installed = saved?.configs ?? []
                    lastSelectedIdentifier = saved?.selectedIdentifier
                    selectedMode = saved?.selectedMode
                    if saved == nil { hasAuthorizedInventory = false }
                    notifyChange()
                }
                let role = try await inventory.checkAccess(for: account)
                try requireCurrent(epoch, token: token)
                let roleCommit = Task {
                    defer { inventoryCommitTask = nil; notifyChange() }
                    try await observeRole(role, accountId: account.uid)
                }
                inventoryCommitTask = roleCommit
                try await roleCommit.value
                try requireCurrent(epoch, token: token)
                let fetched = try await inventory.fetchOptions(for: account, role: role)
                try requireCurrent(epoch, token: token)
                let commit = Task {
                    defer { inventoryCommitTask = nil; notifyChange() }
                    try await publishInventory(fetched, role: role, accountId: account.uid, epoch: epoch, token: token)
                }
                inventoryCommitTask = commit
                try await commit.value
                refreshResult = (refreshEpoch, .refreshed)
            } catch CloudGatewayMacInventoryError.offline {
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                refreshResult = (refreshEpoch, .unavailable)
                let saved = try? await cache.load(accountId: account.uid)
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                options = []
                if let saved, CloudGatewayMacOfflinePolicy.canUseCache(
                    after: CloudGatewayMacInventoryError.offline.cacheFailure, cache: saved
                ) {
                    installed = saved.configs
                    lastSelectedIdentifier = saved.selectedIdentifier
                    selectedMode = saved.selectedMode
                    hasAuthorizedInventory = true
                } else {
                    installed = []
                    lastSelectedIdentifier = nil
                    hasAuthorizedInventory = false
                }
                isOffline = true
                errorMessage = installed.isEmpty ? "Unable to reach CloudGateway. No saved configs are available for this account" : nil
            } catch CloudGatewayMacInventoryError.accessDenied {
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                refreshResult = (refreshEpoch, .denied)
                options = []
                installed = []
                hasAuthorizedInventory = false
                try? await cache.deny(accountId: account.uid)
                guard sessionEpoch == epoch else { return }
                signOut()
                accessResult = .denied
                errorMessage = "Account access was denied. Sign in again after access is restored"
            } catch {
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                refreshResult = (refreshEpoch, .unavailable)
                options = []
                installed = []
                hasAuthorizedInventory = false
                errorMessage = "Unable to refresh inventory. Try Refresh again"
            }
        }
        notifyChange()
    }

    private func publishInventory(
        _ fetched: [CloudGatewayClientOption], role: CloudGatewayMacAccountRole,
        accountId: String, epoch: UInt64, token: CloudGatewayMacSessionToken?
    ) async throws {
        try requireCurrent(epoch, token: token)
        let fetched = fetched.filter {
            !removedIdentifiers.contains("\(accountId)/\($0.client.regionId)/\($0.client.clientId)")
        }
        do {
            try await cache.authorize(accountId: accountId, role: role, options: fetched)
            await inventoryAuthorizationDidCommit()
            try requireCurrent(epoch, token: token)
            let saved = try await cache.load(accountId: accountId)
            try requireCurrent(epoch, token: token)
            guard saved.accessAllowed else { throw CloudGatewayMacCacheError.accessDenied }
            options = fetched
            inventoryReadAt = now()
            installed = saved.configs
            lastSelectedIdentifier = saved.selectedIdentifier
            selectedMode = saved.selectedMode
            isOffline = false
            hasAuthorizedInventory = true
            errorMessage = nil
        } catch {
            if sessionEpoch == epoch { clearInventoryPresentation(for: accountId) }
            throw error
        }
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
        hasAuthorizedInventory = false
        lastSelectedIdentifier = nil
        selectedMode = nil
        notifyChange()
    }

    private func refreshProfiles() {
        guard isStarted, !isShuttingDown else { return }
        profileTask?.cancel()
        profileEpoch &+= 1
        let epoch = profileEpoch
        profileTask = Task { [weak self] in
            guard let self else { return }
            defer { if profileEpoch == epoch { profileTask = nil; notifyChange() } }
            do {
                let snapshot = try await profiles.installedProfiles()
                guard profileEpoch == epoch, !Task.isCancelled else { return }
                profileObservation.didRead(snapshot)
                hasObservedProfiles = true
                profilesObservedAt = now()
            } catch {
                guard profileEpoch == epoch, !Task.isCancelled else { return }
                profileObservation.didFailRead()
            }
        }
    }

    private func clearAccountPresentation() {
        sessionEpoch &+= 1
        sessionFence.changeAccount(to: nil)
        lastSelectedIdentifier = nil
        selectedMode = nil
        pendingLoginInventory = nil
        cancelPendingWork()
        user = nil
        options = []
        removedIdentifiers = []
        installed = []
        isOffline = false
        hasAuthorizedInventory = false
        inventorySchedule.resetInventory()
        deferredInventoryRefresh = false
        deferredInventoryRefreshIsAutomatic = false
        errorMessage = nil
    }

    private func cancelPendingWork() {
        let preservingStop = isStopping
        let pendingCommand = commandTask
        let pendingCreation = creationTask
        let pendingStop = preservingStop ? nil : stopTask
        let pendingCommit = inventoryCommitTask
        inventoryTask?.cancel()
        inventoryEpoch &+= 1
        restorationTask?.cancel()
        commandTask?.cancel()
        creationTask?.cancel()
        if !preservingStop { stopTask?.cancel() }
        inventoryTask = nil
        restorationTask = nil
        commandTask = nil
        creationTask = nil
        if !preservingStop { stopTask = nil }
        sessionFence.invalidate()
        cancellationEpoch &+= 1
        let epoch = cancellationEpoch
        let previousCancellation = cancellationTask
        cancellationTask = Task { [weak self] in
            await previousCancellation?.value
            guard let self else { return }
            if !preservingStop { await configs.cancelPendingWork() }
            await pendingCommand?.value
            await pendingCreation?.value
            await pendingStop?.value
            _ = try? await pendingCommit?.value
            if !preservingStop { await configs.waitForPendingWork() }
            guard cancellationEpoch == epoch else { return }
            cancellationTask = nil
            resumeDeferredInventoryRefresh()
            notifyChange()
        }
    }

    private func resumeDeferredInventoryRefresh() {
        guard deferredInventoryRefresh else { return }
        if deferredInventoryRefreshIsAutomatic,
           !inventorySchedule.isStale(at: inventoryNow()) || inventorySchedule.isIdle(at: inventoryNow()) {
            deferredInventoryRefresh = false
            deferredInventoryRefreshIsAutomatic = false
            notifyChange()
            return
        }
        refreshInventory(force: !deferredInventoryRefreshIsAutomatic)
    }

    private func requireCurrent(_ epoch: UInt64, token: CloudGatewayMacSessionToken? = nil) throws {
        guard isStarted, sessionEpoch == epoch, !Task.isCancelled, !isShuttingDown else { throw CancellationError() }
        if let retainedLoginDeadline, loginNow() >= retainedLoginDeadline { throw CloudGatewayDeviceAuthError.expired }
        if let token {
            guard sessionFence.isCurrent(token), auth.currentUser?.uid == token.accountId else { throw CancellationError() }
        }
    }

    private var visibleErrorMessage: String? {
        (user != nil ? profileObservation.errorMessage : nil) ?? errorMessage
    }

    private var visibleBrowserState: CloudGatewayMacBrowserAuthState {
        if case .signedIn(let authorized) = browser.state, authorized.uid != user?.uid { return .signedOut }
        return browser.state
    }

    var canStartInventoryMutation: Bool {
        stopTask == nil && canSubmitCreation
    }

    private var canSubmitCreation: Bool {
        guard isStarted, !isShuttingDown, commandTask == nil, creationTask == nil, cancellationTask == nil,
              managedStopTask == nil, user != nil, auth.currentUser?.uid == user?.uid,
              inventoryTask == nil, inventoryCommitTask == nil, restorationTask == nil,
              !auth.isCustomTokenSignInSettling else { return false }
        switch browser.state {
        case .requestingCode, .waitingForApproval, .exchangingToken: return false
        default: return true
        }
    }

    private var canIssueLocalCommand: Bool {
        canIssueStop && creationTask == nil
    }

    private var canIssueStop: Bool {
        isStarted && !isShuttingDown && commandTask == nil && stopTask == nil && cancellationTask == nil && managedStopTask == nil
    }

    private var accessState: CloudGatewayMacAccessState {
        if user != nil { return isOffline ? .offline : .online }
        if restorationTask != nil { return .checking }
        return accessResult ?? .unverified
    }

    public var session: CloudGatewayMacSessionToken? {
        sessionFence.currentToken
    }

    func evictCachedClient(identifier: String, session: CloudGatewayMacSessionToken) async throws {
        let epoch = sessionEpoch
        try requireCurrent(epoch, token: session)
        guard user?.uid == session.accountId, commandTask != nil,
              inventoryTask == nil, inventoryCommitTask == nil, restorationTask == nil,
              cancellationTask == nil, managedStopTask == nil, !auth.isCustomTokenSignInSettling else {
            throw CloudGatewayMacConfigError.busy
        }
        let saved = try await cache.evict(identifier: identifier, accountId: session.accountId)
        await cacheEvictionDidCommit()
        try requireCurrent(epoch, token: session)
        installed = saved.configs
        lastSelectedIdentifier = saved.selectedIdentifier
        selectedMode = saved.selectedMode
        options.removeAll { "\(session.accountId)/\($0.client.regionId)/\($0.client.clientId)" == identifier }
        notifyChange()
    }

    private var clientMetadata: [CloudGatewayMacClientMetadata] {
        guard let accountId = user?.uid else { return [] }
        if isOffline || options.isEmpty {
            let accountConfigs = installed.filter { $0.accountId == accountId }
            let regions = CloudGatewayConfigSelection.offlineRegions(from: accountConfigs.map(\.snapshot))
            return accountConfigs.map { config in
                let profile = profileObservation.profiles.first {
                    $0.identifier == config.identifier && $0.reference == (try? config.reference)
                }
                return CloudGatewayMacClientMetadata(
                    identifier: config.identifier, regionId: config.snapshot.regionId,
                    regionName: regions.first { $0.regionId == config.snapshot.regionId }?.displayName ?? config.snapshot.regionId,
                    regionOrder: 1000, clientName: config.snapshot.clientDisplayName, ownerLabel: nil,
                    internalIp: config.snapshot.assignedTunnelIpv4,
                    connectionUrl: Self.connectionUrl(hostname: config.snapshot.serverEndpointHostname, ipv4: config.snapshot.serverEndpointIpv4),
                    cloudState: config.snapshot.status,
                    eligibility: config.snapshot.status == .active ? .eligible : .inactive, isInstalled: true,
                    source: .cache, readAt: config.snapshot.readAt, updatedAt: config.snapshot.updatedAt,
                    status: profile?.status
                )
            }
        }
        return options.filter { $0.client.status != .removed }.map { option in
            let identifier = "\(accountId)/\(option.client.regionId)/\(option.client.clientId)"
            return CloudGatewayMacClientMetadata(
                identifier: identifier, regionId: option.client.regionId, regionName: option.regionDisplayName,
                regionOrder: option.region?.displayOrder ?? 1000, clientName: option.client.displayName,
                ownerLabel: option.client.ownerEmail, internalIp: option.client.assignedTunnelIpv4,
                connectionUrl: Self.connectionUrl(hostname: option.client.serverEndpointHostname, ipv4: option.client.serverEndpointIpv4),
                cloudState: option.client.status, eligibility: Self.eligibility(of: option),
                isInstalled: installed.contains { $0.accountId == accountId && $0.identifier == identifier },
                source: .cloud, readAt: inventoryReadAt, updatedAt: option.client.updatedAt,
                status: profileObservation.profiles.first { $0.identifier == identifier }?.status
            )
        }
    }

    private static func connectionUrl(hostname: String?, ipv4: String?) -> String? {
        for value in [hostname, ipv4] {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func eligibility(of option: CloudGatewayClientOption) -> CloudGatewayMacClientEligibility {
        guard option.client.status == .active else { return .inactive }
        guard option.client.hasUsableConfig else { return .configMissing }
        return option.region?.enabled == true ? .eligible : .regionUnavailable
    }

    private func hasConnectableConfig(identifier: String, accountId: String) -> Bool {
        if !isOffline, !options.isEmpty {
            return options.contains {
                "\(accountId)/\($0.client.regionId)/\($0.client.clientId)" == identifier
                    && Self.eligibility(of: $0) == .eligible
            }
        }
        return installed.contains {
            $0.accountId == accountId && $0.identifier == identifier && $0.snapshot.status == .active
        }
    }

    private func notifyChange() {
        guard isStarted, !isShuttingDown else { return }
        onChange?()
    }

    public func managedUpdateObservation() async throws -> CloudGatewayMacManagedUpdateObservation {
        let epoch = sessionEpoch
        let observed = try await profiles.installedProfiles()
        guard epoch == sessionEpoch, !isShuttingDown else { throw CloudGatewayMacConfigError.cancelled }
        return .init(accountId: user?.uid, profiles: observed.map { .init(identifier: $0.identifier, status: $0.status) },
                     authorizedIdentifiers: clientMetadata.filter { $0.eligibility == .eligible }.map(\.identifier),
                     isRestoringSession: restorationTask != nil || auth.isCustomTokenSignInSettling
                        || !hasAuthorizedInventory && (inventoryTask != nil || inventoryCommitTask != nil
                            || deferredInventoryRefresh || pendingLoginInventory != nil),
                     accessAuthorized: hasAuthorizedInventory && user != nil && user?.uid == auth.currentUser?.uid)
    }

    public func cancelManagedReconnect(identifier: String) async {
        guard managedReconnectIdentifier == identifier, let connection = commandTask else { return }
        connection.cancel()
        await connection.value
        await cancellationTask?.value
    }

    @discardableResult
    // A nil identifier starts this account's last selection
    public func connectClient(
        identifier requested: String?,
        displacingOtherProfiles: Bool = true,
        onCompletion: (@MainActor (CloudGatewayMacCommandOutcome) -> Void)? = nil
    ) -> Bool {
        let resolved = requested ?? lastSelectedIdentifier
        let rejection: CloudGatewayMacCommandFailure? = if !canIssueLocalCommand { .busy }
            else if setupState != .ready { setupState.commandFailure }
            else if user == nil || auth.currentUser?.uid != user?.uid { .signInRequired }
            else if selectedMode == nil { .configUnavailable }
            else if let resolved, hasConnectableConfig(identifier: resolved, accountId: user?.uid ?? "") { nil }
            else { requested == nil ? .selectionUnavailable : .configUnavailable }
        guard rejection == nil, let account = user, let identifier = resolved else {
            onCompletion?(.failed(rejection ?? .signInRequired))
            return false
        }
        let epoch = sessionEpoch
        let token = sessionFence.currentToken
        let pendingCommit = inventoryCommitTask
        inventoryTask?.cancel()
        inventoryTask = nil
        inventoryEpoch &+= 1
        managedReconnectIdentifier = displacingOtherProfiles ? nil : identifier
        commandTask = Task { [weak self] in
            guard let self else { onCompletion?(.unknown); return }
            var outcome = CloudGatewayMacCommandOutcome.failed(.vpnFailed)
            var connectInFlight = false
            var startRequested: Bool?
            defer {
                managedReconnectIdentifier = nil
                if sessionEpoch == epoch { commandTask = nil; resumeDeferredInventoryRefresh(); refreshProfiles(); notifyChange() }
                onCompletion?(outcome)
            }
            do {
                try await pendingCommit?.value
                try requireCurrent(epoch, token: token)
                guard hasConnectableConfig(identifier: identifier, accountId: account.uid) else {
                    throw CloudGatewayMacConfigError.unavailable
                }
                guard let mode = selectedMode else { throw CloudGatewayMacConfigError.invalidConfig }
                let connection = try await connectConfiguration(
                    identifier: identifier, accountId: account.uid, mode: mode,
                    displacingOtherProfiles: displacingOtherProfiles, epoch: epoch, token: token,
                    onConnect: { connectInFlight = $0 }
                )
                let config = connection.config
                startRequested = connection.started
                connectInFlight = false
                try requireCurrent(epoch, token: token)
                try await cache.select(identifier: config.identifier, accountId: account.uid)
                try requireCurrent(epoch, token: token)
                let savedMetadata = try await cache.load(accountId: account.uid)
                try requireCurrent(epoch, token: token)
                installed = savedMetadata.configs
                lastSelectedIdentifier = savedMetadata.selectedIdentifier
                selectedMode = savedMetadata.selectedMode
                try requireCurrent(epoch, token: token)
                outcome = Self.startOutcome(startRequested == true, identifier: identifier, warning: nil)
                errorMessage = nil
            } catch {
                if let startRequested {
                    // Persistence failures cannot undo a start that macOS already accepted
                    outcome = Self.startOutcome(startRequested, identifier: identifier, warning: .selectionNotSaved)
                } else if isShuttingDown || connectInFlight && (error is CancellationError
                    || error as? CloudGatewayMacConfigError == .cancelled || Task.isCancelled || sessionEpoch != epoch) {
                    outcome = .unknown
                } else { outcome = .failed(Self.failure(for: error)) }
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                if startRequested != nil {
                    errorMessage = "VPN connection was accepted, but offline metadata could not refresh. Choose Refresh before trying again"
                    return
                }
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

    @discardableResult
    public func setMode(
        _ mode: CloudGatewayRoutingMode,
        onCompletion: @escaping @MainActor (CloudGatewayMacCommandOutcome) -> Void
    ) -> Bool {
        let rejection: CloudGatewayMacCommandFailure? = if !canIssueLocalCommand { .busy }
            else if user == nil || auth.currentUser?.uid != user?.uid { .signInRequired }
            else if !canStartInventoryMutation { .busy }
            else if !hasAuthorizedInventory { .accessDenied }
            else { nil }
        guard rejection == nil, let account = user, let token = sessionFence.currentToken else {
            onCompletion(.failed(rejection ?? .signInRequired))
            return false
        }
        let epoch = sessionEpoch
        commandTask = Task { [weak self] in
            guard let self else { onCompletion(.unknown); return }
            var outcome = CloudGatewayMacCommandOutcome.failed(.vpnFailed)
            var connectInFlight = false
            var acceptedConnection: (identifier: String, started: Bool)?
            defer {
                if sessionEpoch == epoch {
                    commandTask = nil
                    resumeDeferredInventoryRefresh()
                    refreshProfiles()
                    notifyChange()
                }
                onCompletion(outcome)
            }
            do {
                try requireCurrent(epoch, token: token)
                let observed = try await profiles.installedProfiles()
                try requireCurrent(epoch, token: token)
                let active = observed.filter(\.needsConfirmedStop)
                guard active.count <= 1 else { throw CloudGatewayMacConfigError.busy }
                if let profile = active.first {
                    guard hasConnectableConfig(identifier: profile.identifier, accountId: account.uid),
                          profile.identifier.hasPrefix("\(account.uid)/") else {
                        throw CloudGatewayMacConfigError.unavailable
                    }
                    guard setupState == .ready else {
                        outcome = .failed(setupState.commandFailure)
                        return
                    }
                    if selectedMode == mode, profile.mode == mode,
                       profile.status == .connected || profile.status == .reasserting || profile.status == .connecting {
                        outcome = .alreadyActive(identifier: profile.identifier, warning: nil)
                        return
                    }
                } else if selectedMode == mode {
                    outcome = .completed(warning: nil)
                    return
                }
                try await cache.selectMode(mode, accountId: account.uid)
                try requireCurrent(epoch, token: token)
                selectedMode = mode
                notifyChange()
                guard let active = active.first else {
                    errorMessage = nil
                    outcome = .completed(warning: nil)
                    return
                }
                let connection = try await connectConfiguration(
                    identifier: active.identifier, accountId: account.uid, mode: mode,
                    displacingOtherProfiles: false, epoch: epoch, token: token,
                    onConnect: { connectInFlight = $0 }
                )
                acceptedConnection = (connection.config.identifier, connection.started)
                connectInFlight = false
                try requireCurrent(epoch, token: token)
                let savedMetadata = try await cache.load(accountId: account.uid)
                try requireCurrent(epoch, token: token)
                installed = savedMetadata.configs
                lastSelectedIdentifier = savedMetadata.selectedIdentifier
                selectedMode = savedMetadata.selectedMode
                outcome = Self.startOutcome(connection.started, identifier: connection.config.identifier, warning: nil)
                errorMessage = nil
            } catch {
                if let acceptedConnection {
                    outcome = Self.startOutcome(acceptedConnection.started, identifier: acceptedConnection.identifier, warning: .selectionNotSaved)
                } else if isShuttingDown || connectInFlight && (Task.isCancelled || error is CancellationError
                    || error as? CloudGatewayMacConfigError == .cancelled || sessionEpoch != epoch) {
                    outcome = .unknown
                } else { outcome = .failed(Self.failure(for: error)) }
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                if acceptedConnection != nil {
                    errorMessage = "VPN connection was accepted, but offline metadata could not refresh. Choose Refresh before trying again"
                    return
                }
                errorMessage = "VPN mode could not be applied. Check VPN status before trying again"
            }
        }
        notifyChange()
        return true
    }

    private func connectConfiguration(
        identifier: String, accountId: String, mode: CloudGatewayRoutingMode,
        displacingOtherProfiles: Bool, epoch: UInt64, token: CloudGatewayMacSessionToken?,
        onConnect: (Bool) -> Void
    ) async throws -> (config: CloudGatewayMacInstalledConfig, started: Bool) {
        var started = false
        let option = options.first { "\(accountId)/\($0.client.regionId)/\($0.client.clientId)" == identifier }
        let saved = installed.first { $0.identifier == identifier && $0.accountId == accountId }
        let latestProfiles = try await profiles.installedProfiles()
        try requireCurrent(epoch, token: token)
        if !displacingOtherProfiles, latestProfiles.contains(where: { $0.needsConfirmedStop && $0.identifier != identifier }) {
            throw CloudGatewayMacConfigError.busy
        }
        let savedProfileExists = saved.map { config in
            latestProfiles.contains { $0.identifier == config.identifier && $0.reference == (try? config.reference) }
        } ?? false
        var config: CloudGatewayMacInstalledConfig
        if let saved, isOffline || option == nil || option.map({ CloudGatewayConfigSelection.configMatches(saved.snapshot, option: $0) }) == true {
            let authorized = try await cache.load(accountId: accountId)
            try requireCurrent(epoch, token: token)
            guard authorized.accessAllowed, authorized.configs.contains(where: {
                $0.identifier == saved.identifier && $0.snapshot.configHash == saved.snapshot.configHash
                    && $0.snapshot.secretReference == saved.snapshot.secretReference
            }) else { throw CloudGatewayMacConfigError.unavailable }
            config = saved
        } else if let option, !isOffline {
            config = try await configs.install(option: option, accountId: accountId, mode: mode)
        } else { throw CloudGatewayMacConfigError.unavailable }
        let usesSavedConfig = config == saved
        config.mode = mode
        try requireCurrent(epoch, token: token)
        do {
            if usesSavedConfig, !savedProfileExists { try await configs.restore(config) }
            try requireCurrent(epoch, token: token)
            onConnect(true)
            started = try await configs.connect(config, displacingOtherProfiles: displacingOtherProfiles)
        } catch CloudGatewayMacConfigError.unavailable {
            onConnect(false)
            try requireCurrent(epoch, token: token)
            guard usesSavedConfig, let option, !isOffline else { throw CloudGatewayMacConfigError.unavailable }
            config = try await configs.install(option: option, accountId: accountId, mode: mode)
            try requireCurrent(epoch, token: token)
            onConnect(true)
            started = try await configs.connect(config, displacingOtherProfiles: displacingOtherProfiles)
        }
        return (config, started)
    }

    private static func startOutcome(
        _ startRequested: Bool, identifier: String, warning: CloudGatewayMacCommandWarning?
    ) -> CloudGatewayMacCommandOutcome {
        startRequested ? .startRequested(identifier: identifier, warning: warning)
            : .alreadyActive(identifier: identifier, warning: warning)
    }

    private static func failure(for error: Error) -> CloudGatewayMacCommandFailure {
        switch error {
        case CloudGatewayMacConfigError.busy: .busy
        case CloudGatewayMacConfigError.clientActive: .clientActive
        case CloudGatewayMacConfigError.stopTimedOut: .stopTimedOut
        case CloudGatewayMacCacheError.accessDenied: .accessDenied
        case CloudGatewayMacConfigError.unavailable, CloudGatewayMacConfigError.invalidConfig, is CloudGatewayMacCacheError:
            .configUnavailable
        // Session fences cancel work before macOS receives a start
        case is CancellationError, CloudGatewayMacConfigError.cancelled: .signInRequired
        default: .vpnFailed
        }
    }

    @discardableResult
    public func removeClient(
        identifier: String,
        onCompletion: (@MainActor (CloudGatewayMacCommandOutcome) -> Void)? = nil
    ) -> Bool {
        let rejection: CloudGatewayMacCommandFailure? = if !canIssueLocalCommand { .busy }
            else if user == nil || auth.currentUser?.uid != user?.uid { .signInRequired }
            else if !canStartInventoryMutation { .busy }
            else if !CloudGatewayMacProfileMetadata.validIdentifier(identifier)
                || identifier.split(separator: "/").first != user.map({ Substring($0.uid) }) { .configUnavailable }
            else { nil }
        guard rejection == nil, let account = user, let token = sessionFence.currentToken else {
            onCompletion?(.failed(rejection ?? .signInRequired))
            return false
        }
        let epoch = sessionEpoch
        commandTask = Task { [weak self] in
            guard let self else { onCompletion?(.unknown); return }
            var outcome = CloudGatewayMacCommandOutcome.failed(.internalError)
            var dispatched = false
            var removed = false
            var cleanedUp = false
            let authorize: @MainActor @Sendable () throws -> Void = { [weak self] in
                guard let self else { throw CancellationError() }
                try self.requireCurrent(epoch, token: token)
                guard self.user?.uid == account.uid, !self.auth.isCustomTokenSignInSettling else {
                    throw CancellationError()
                }
            }
            defer {
                if sessionEpoch == epoch {
                    commandTask = nil
                    resumeDeferredInventoryRefresh()
                    refreshProfiles()
                    notifyChange()
                }
                onCompletion?(outcome)
            }
            do {
                try authorize()
                let role = try await inventory.checkAccess(for: account)
                try authorize()
                try await observeRole(role, accountId: account.uid)
                try authorize()
                let fetched = try await inventory.fetchOptions(for: account, role: role)
                try authorize()
                let matches = fetched.filter { "\(account.uid)/\($0.client.regionId)/\($0.client.clientId)" == identifier }
                guard !removedIdentifiers.contains(identifier), matches.count == 1,
                      let target = matches.first?.client, target.status != .removed,
                      let owner = target.ownerUid, !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CloudGatewayMacConfigError.unavailable
                }
                guard role == .admin || owner == account.uid else { throw CloudGatewayMacInventoryError.accessDenied }
                try await configs.validateInactiveClient(identifier: identifier, authorize: authorize)
                try authorize()
                try await evictCachedClient(identifier: identifier, session: token)
                try authorize()
                _ = try await inventory.deleteClient(
                    clientId: target.clientId, ownerUid: owner, regionId: target.regionId, for: account,
                    authorize: { [configs] in
                        try authorize()
                        try await configs.validateInactiveClient(identifier: identifier, authorize: authorize)
                        try authorize()
                    },
                    onDispatch: { dispatched = true }
                )
                // Record success before any cancellable local work or session check
                removed = true
                outcome = .completed(warning: .localCleanupIncomplete)
                if sessionEpoch == epoch, sessionFence.isCurrent(token) { removedIdentifiers.insert(identifier) }
                try authorize()
                do {
                    try await configs.removeClientProfile(identifier: identifier, authorize: authorize)
                    try authorize()
                    cleanedUp = true
                } catch {
                    try authorize()
                }
                let refreshedRole = try await inventory.checkAccess(for: account)
                try authorize()
                try await observeRole(refreshedRole, accountId: account.uid)
                try authorize()
                let remaining = try await inventory.fetchOptions(for: account, role: refreshedRole)
                try authorize()
                try await publishInventory(remaining, role: refreshedRole, accountId: account.uid, epoch: epoch, token: token)
                try authorize()
                inventorySchedule.complete(at: inventoryNow(), succeeded: true, jitter: inventoryJitter())
                outcome = .completed(warning: cleanedUp ? nil : .localCleanupIncomplete)
                errorMessage = cleanedUp ? nil
                    : "Client was removed. Disconnect it explicitly or stop it in System Settings before local cleanup, then Refresh"
            } catch {
                let denied: Bool
                switch error {
                case CloudGatewayAppError.apiAccessDenied(_): denied = true
                case CloudGatewayMacInventoryError.accessDenied: denied = !dispatched || removed
                default: denied = false
                }
                let isCurrent = (try? authorize()) != nil
                if removed {
                    outcome = .completed(warning: cleanedUp && isCurrent ? .inventoryNotRefreshed : .localCleanupIncomplete)
                } else if denied { outcome = .failed(.accessDenied) }
                else if dispatched { outcome = .unknown }
                else if error is CloudGatewayMacInventoryError || error is URLError { outcome = .failed(.networkUnavailable) }
                else if case CloudGatewayAppError.accessDenied(_) = error { outcome = .failed(.accessDenied) }
                else { outcome = .failed(Self.failure(for: error)) }
                guard isCurrent else { return }
                if denied {
                    if removed { outcome = .completed(warning: .localCleanupIncomplete) }
                    clearInventoryPresentation(for: account.uid)
                    try? await cache.deny(accountId: account.uid)
                    guard (try? authorize()) != nil else { return }
                    signOut()
                    accessResult = .denied
                    errorMessage = "Account access was denied. Sign in again after access is restored"
                } else if removed {
                    errorMessage = cleanedUp
                        ? "Client was removed, but the client list could not refresh. Choose Refresh"
                        : "Client was removed. Disconnect it explicitly or stop it in System Settings before local cleanup, then Refresh"
                } else if dispatched {
                    errorMessage = "Could not confirm whether the client was removed. Refresh the client list before trying again"
                } else if error as? CloudGatewayMacConfigError == .clientActive {
                    errorMessage = "Disconnect this client and wait for it to stop before removing it"
                } else {
                    errorMessage = "Client could not be removed. Refresh before trying again"
                }
            }
        }
        notifyChange()
        return true
    }

    public func clientCreationContext() -> CloudGatewayMacClientCreationContext? {
        guard canStartInventoryMutation, let session = sessionFence.currentToken else { return nil }
        return CloudGatewayMacClientCreationContext(session: session, controllerId: controllerId)
    }

    public func loadCreateRegions(context: CloudGatewayMacClientCreationContext) async throws -> [CloudGatewayRegion] {
        guard canStartInventoryMutation, let account = user,
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
            accessResult = .denied
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
        context: CloudGatewayMacClientCreationContext,
        onCompletion: (@MainActor (CloudGatewayMacCommandOutcome) -> Void)? = nil
    ) -> Bool {
        guard canSubmitCreation, let account = user,
              context.controllerId == controllerId, sessionFence.isCurrent(context.session),
              context.session.accountId == account.uid else { return false }
        let epoch = sessionEpoch
        let token = context.session
        creationTask = Task { [weak self] in
            guard let self else { onCompletion?(.unknown); return }
            var clientWasCreated = false
            var creationAttempted = false
            var outcome = CloudGatewayMacCommandOutcome.failed(.internalError)
            defer {
                if sessionEpoch == epoch { creationTask = nil; resumeDeferredInventoryRefresh(); notifyChange() }
                onCompletion?(clientWasCreated && outcome != .completed(warning: nil)
                    ? .completed(warning: .inventoryNotRefreshed) : outcome)
            }
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
                clientWasCreated = true
                try requireCurrent(epoch, token: token)

                let fetched = try await inventory.fetchOptions(for: account, role: role)
                try requireCurrent(epoch, token: token)
                try await publishInventory(fetched, role: role, accountId: account.uid, epoch: epoch, token: token)
                inventorySchedule.complete(at: inventoryNow(), succeeded: true, jitter: inventoryJitter())
                outcome = .completed(warning: nil)
            } catch CloudGatewayMacInventoryError.accessDenied, CloudGatewayAppError.apiAccessDenied(_) {
                outcome = .failed(.accessDenied)
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                clearInventoryPresentation(for: account.uid)
                try? await cache.deny(accountId: account.uid)
                guard sessionEpoch == epoch, !Task.isCancelled, auth.currentUser?.uid == account.uid else { return }
                signOut()
                accessResult = .denied
                errorMessage = "Account access was denied. Sign in again after access is restored"
            } catch {
                if creationAttempted || isShuttingDown { outcome = .unknown }
                else if error is CancellationError { outcome = .failed(.signInRequired) }
                else if error as? CloudGatewayMacInventoryError != nil { outcome = .failed(.networkUnavailable) }
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
    public func disconnectClient(
        identifier: String,
        onCompletion: (@MainActor (CloudGatewayMacCommandOutcome) -> Void)? = nil
    ) -> Bool {
        if managedReconnectIdentifier != nil { return stopAfterManagedReconnect(identifier: identifier, onCompletion: onCompletion) }
        let rejection: CloudGatewayMacCommandFailure? = if !canIssueStop { .busy }
            else if user == nil || auth.currentUser?.uid != user?.uid { .signInRequired }
            else if !hasAuthorizedInventory { .accessDenied }
            else if clientMetadata.filter({ $0.identifier == identifier }).count != 1 { .configUnavailable }
            else { nil }
        guard rejection == nil, let token = sessionFence.currentToken else {
            onCompletion?(.failed(rejection ?? .signInRequired))
            return false
        }
        let epoch = sessionEpoch
        stopTask = Task { [weak self] in
            guard let self else { onCompletion?(.unknown); return }
            var outcome = CloudGatewayMacCommandOutcome.unknown
            defer {
                if sessionEpoch == epoch {
                    stopTask = nil
                    resumeDeferredInventoryRefresh()
                    refreshProfiles()
                    notifyChange()
                }
                onCompletion?(outcome)
            }
            do {
                try requireCurrent(epoch, token: token)
                try await configs.disconnectClient(identifier: identifier) { [weak self] in
                    guard let self else { throw CancellationError() }
                    try self.requireCurrent(epoch, token: token)
                    guard self.hasAuthorizedInventory,
                          self.clientMetadata.filter({ $0.identifier == identifier }).count == 1 else {
                        throw CloudGatewayMacConfigError.unavailable
                    }
                }
                try requireCurrent(epoch, token: token)
                errorMessage = nil
                outcome = .completed(warning: nil)
            } catch {
                guard sessionEpoch == epoch, !Task.isCancelled, !isShuttingDown else { return }
                outcome = .failed(Self.failure(for: error))
                errorMessage = "VPN has not confirmed stop. Try again after checking System Settings"
            }
        }
        notifyChange()
        return true
    }

    private func stopAfterManagedReconnect(
        identifier: String?, onCompletion: (@MainActor (CloudGatewayMacCommandOutcome) -> Void)?
    ) -> Bool {
        guard managedStopTask == nil, let connection = commandTask, isStarted, !isShuttingDown else {
            onCompletion?(.failed(.busy))
            return false
        }
        if identifier == nil || identifier == managedReconnectIdentifier { connection.cancel() }
        managedStopTask = Task { [weak self] in
            await connection.value
            guard let self else { onCompletion?(.unknown); return }
            await cancellationTask?.value
            guard !isShuttingDown, !Task.isCancelled else { onCompletion?(.unknown); return }
            managedStopTask = nil
            if let identifier { _ = disconnectClient(identifier: identifier, onCompletion: onCompletion) }
            else { _ = turnOff(onCompletion: onCompletion) }
        }
        return true
    }

    @discardableResult
    public func turnOff(onCompletion: (@MainActor (CloudGatewayMacCommandOutcome) -> Void)? = nil) -> Bool {
        if managedReconnectIdentifier != nil { return stopAfterManagedReconnect(identifier: nil, onCompletion: onCompletion) }
        guard canIssueStop else {
            onCompletion?(.failed(.busy))
            return false
        }
        isStopping = true
        stopTask = Task { [weak self] in
            guard let self else { onCompletion?(.unknown); return }
            var outcome = CloudGatewayMacCommandOutcome.unknown
            defer {
                isStopping = false
                stopTask = nil
                resumeLoginInventoryAfterStop()
                resumeDeferredInventoryRefresh()
                refreshProfiles()
                notifyChange()
                onCompletion?(outcome)
            }
            do {
                try Task.checkCancellation()
                try await configs.turnOff()
                try Task.checkCancellation()
                errorMessage = nil
                outcome = .completed(warning: nil)
            } catch {
                if !Task.isCancelled, !isShuttingDown {
                    if error as? CloudGatewayMacConfigError != .cancelled { outcome = .failed(Self.failure(for: error)) }
                    errorMessage = "VPN has not confirmed stop. Try again after checking System Settings"
                }
            }
        }
        notifyChange()
        return true
    }

    public func signIn() {
        guard isStarted, restorationTask == nil, !isShuttingDown else { return }
        accessResult = nil
        errorMessage = nil
        if auth.currentUser != nil { restoreSession() }
        else { _ = browser.begin() }
        notifyChange()
    }

    public func cancelSignIn() {
        guard let status = browser.loginStatus else { return }
        _ = cancelLogin(attemptId: status.attemptId)
    }

    public func beginLogin(attemptId: UUID, origin: CloudGatewayMacLoginOrigin) -> CloudGatewayMacLoginStatus {
        if user != nil { return .init(attemptId: attemptId, origin: origin, phase: .finished, result: .authorized) }
        if let current = retainedLogin ?? browser.loginStatus, current.attemptId == attemptId { return current }
        if let current = browser.loginStatus, current.phase != .finished {
            return .init(attemptId: attemptId, origin: origin, phase: .finished, result: .busy)
        }
        if let retainedLogin, retainedLogin.phase != .finished {
            return .init(attemptId: attemptId, origin: origin, phase: .finished, result: .busy)
        }
        guard isStarted, !isShuttingDown else {
            return .init(attemptId: attemptId, origin: origin, phase: .finished, result: .unavailable)
        }
        if auth.currentUser != nil, !auth.isCustomTokenSignInSettling {
            restoreSession()
            let status = CloudGatewayMacLoginStatus(attemptId: attemptId, origin: origin, phase: .restoring)
            retainedLogin = status
            let restoration = restorationTask
            let end = loginNow() + .seconds(30)
            retainedLoginDeadline = end
            retainedLoginTimer = Task { [weak self, loginTimer, loginNow] in
                do { try await loginTimer(max(.zero, end - loginNow())) } catch { return }
                guard let self, retainedLogin?.attemptId == attemptId, retainedLogin?.phase != .finished else { return }
                clearAccountPresentation()
                finishRetainedLogin(attemptId, result: .expired)
            }
            retainedLoginTask = Task { [weak self] in
                await restoration?.value
                guard let self, !Task.isCancelled, retainedLogin?.attemptId == attemptId,
                      retainedLogin?.phase != .finished else { return }
                if loginNow() >= end {
                    clearAccountPresentation()
                    finishRetainedLogin(attemptId, result: .expired)
                } else {
                    // Firebase signs out once it rejects the retained credentials
                    finishRetainedLogin(attemptId, result: user != nil ? .authorized
                        : accessResult == .denied ? .denied : auth.currentUser == nil ? .signInRequired : .offline)
                }
            }
            return status
        }
        retainedLogin = nil
        guard browser.begin(attemptId: attemptId, origin: origin) else {
            return .init(attemptId: attemptId, origin: origin, phase: .finished, result: .busy)
        }
        return browser.loginStatus!
    }

    public func loginStatus(attemptId: UUID) -> CloudGatewayMacLoginStatus {
        if let current = retainedLogin ?? browser.loginStatus, current.attemptId == attemptId { return current }
        if user != nil { return .init(attemptId: attemptId, origin: .cli, phase: .finished, result: .authorized) }
        if restorationTask != nil { return .init(attemptId: attemptId, origin: .cli, phase: .restoring) }
        return .init(attemptId: attemptId, origin: .cli, phase: .finished,
                     result: accessResult == .denied ? .denied : .unavailable)
    }

    public func cancelLogin(attemptId: UUID) -> CloudGatewayMacLoginStatus {
        if retainedLogin?.attemptId == attemptId, retainedLogin?.phase != .finished {
            clearAccountPresentation()
            finishRetainedLogin(attemptId, result: .cancelled)
        } else { browser.cancel(attemptId: attemptId) }
        notifyChange()
        return loginStatus(attemptId: attemptId)
    }

    private func completeRetainedLoginAuthorization() {
        guard let retainedLogin, retainedLogin.phase == .restoring else { return }
        finishRetainedLogin(retainedLogin.attemptId, result: .authorized)
    }

    private func finishRetainedLogin(_ id: UUID, result: CloudGatewayMacLoginStatus.Result) {
        guard let current = retainedLogin, current.attemptId == id else { return }
        retainedLoginDeadline = nil
        retainedLoginTimer?.cancel()
        retainedLoginTimer = nil
        retainedLoginTask?.cancel()
        retainedLoginTask = nil
        retainedLogin = .init(attemptId: id, origin: current.origin, phase: .finished, result: result)
        notifyChange()
    }

    @discardableResult
    public func signOut() -> Bool {
        guard isStarted, !isShuttingDown else { return false }
        onAuthenticationChange?()
        accessResult = nil
        if let retainedLogin, retainedLogin.phase != .finished { finishRetainedLogin(retainedLogin.attemptId, result: .cancelled) }
        clearAccountPresentation()
        let didSignOut = browser.signOut()
        notifyChange()
        return didSignOut
    }

    public func refresh() {
        guard isStarted, !isShuttingDown else { return }
        refreshProfiles()
        if user != nil { refreshInventory() }
        else { restoreSession() }
        notifyChange()
    }

    // Waits only for the controller's own work, so a departed caller cannot cancel the fetch.
    // A repeated call joins a fetch already in flight and reports that fetch's result
    public func awaitRefresh() async -> CloudGatewayMacRefreshResult {
        guard isStarted, !isShuttingDown else { return .skipped }
        refreshProfiles()
        if user == nil {
            guard auth.currentUser != nil else { return .signInRequired }
            restoreSession()
            notifyChange()
            guard let restoration = restorationTask else { return .skipped }
            await restoration.value
            guard user != nil else {
                if accessResult == .denied { return .denied }
                return auth.currentUser == nil ? .signInRequired : .unavailable
            }
            if isOffline { return .unavailable }
        } else {
            refreshInventory()
            notifyChange()
        }
        if deferredInventoryRefresh {
            let token = sessionFence.currentToken
            await commandTask?.value
            await creationTask?.value
            await stopTask?.value
            await cancellationTask?.value
            _ = try? await inventoryCommitTask?.value
            guard token == sessionFence.currentToken, !isShuttingDown else { return .superseded }
            resumeDeferredInventoryRefresh()
        }
        let epoch = inventoryEpoch
        if let task = inventoryTask { await task.value }
        guard let refreshResult, refreshResult.epoch == epoch else { return .superseded }
        return refreshResult.result
    }

    deinit {
        authRegistration?.cancel()
    }
}

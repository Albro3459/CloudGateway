import CloudGatewayKit
import CloudGatewayMacCore
import CloudGatewayMacIPC
import Foundation

@MainActor
private final class InstalledIdentityReply {
    typealias Reply = Result<CloudGatewayMacBuildIdentity?, CloudGatewayMacControllerFailure>
    private var result: Reply?
    private var continuations: [CheckedContinuation<Reply, Never>] = []
    var timer: Task<Void, Never>?

    func value() async -> Reply {
        if let result { return result }
        return await withCheckedContinuation { continuations.append($0) }
    }

    func finish(_ result: Reply) {
        guard self.result == nil else { return }
        self.result = result
        timer?.cancel()
        timer = nil
        let waiting = continuations
        continuations = []
        waiting.forEach { $0.resume(returning: result) }
    }
}

@MainActor
public struct CloudGatewayMacPreparedClient {
    public let regions: [CloudGatewayRegion]
    let submit: (String, String, @escaping @MainActor (CloudGatewayMacCommandOutcome) -> Void) -> Bool

    public init(regions: [CloudGatewayRegion],
                submit: @escaping (String, String, @escaping @MainActor (CloudGatewayMacCommandOutcome) -> Void) -> Bool) {
        self.regions = regions
        self.submit = submit
    }
}

@MainActor
public struct CloudGatewayMacControllerEffects {
    let snapshot: (CloudGatewayMacSetupState, Bool) -> CloudGatewayMacControllerState
    let hasPendingWork: () -> Bool
    let perform: (CloudGatewayMacControllerRequest, @escaping @MainActor (CloudGatewayMacCommandOutcome) -> Void) -> Bool
    let session: () -> CloudGatewayMacSessionToken?
    let refresh: () async -> CloudGatewayMacRefreshResult
    let refreshTimeout: Duration
    let prepareClient: () async throws -> CloudGatewayMacPreparedClient
    let setSetupState: (CloudGatewayMacSetupState) -> Void
    let hasAnyActiveTunnel: () async throws -> Bool
    let installedIdentity: () async -> CloudGatewayMacBuildIdentity?
    let installationTimeout: Duration
    let installationTimer: (Duration) async throws -> Void
    let extensionIdentity: () throws -> CloudGatewayMacBuildIdentity
    let ping: (CloudGatewayMacBuildIdentity) async throws -> CloudGatewayMacExtensionVersion?
    let registrationReadiness: () async -> CloudGatewayMacSetupState
    let initializeRuntime: () -> Void
    let isRuntimeInitialized: () -> Bool
    let diagnostics: () async -> CloudGatewayMacControllerDiagnostics
    let login: (CloudGatewayMacControllerRequest) -> CloudGatewayMacLoginStatus?
    let userActivity: (Bool) -> Void
    let refreshInventoryIfDue: () -> Void
    let setAutomaticInventoryRefreshAllowed: (Bool, Bool) -> Void
    let monotonicNow: () -> Duration
    let managedUpdateObservation: () async throws -> CloudGatewayMacManagedUpdateObservation
    let reconnectClient: (String, @escaping @MainActor (CloudGatewayMacCommandOutcome) -> Void) -> Bool
    let cancelManagedReconnect: (String) async -> Void
    let activateExtension: (UUID, CloudGatewayMacBuildIdentity, @escaping @MainActor (CloudGatewayMacExtensionActivationEvent) -> Void) -> Bool
    let activationIsPending: () -> Bool
    let now: () -> Date

    public init(
        snapshot: @escaping (CloudGatewayMacSetupState, Bool) -> CloudGatewayMacControllerState,
        hasPendingWork: @escaping () -> Bool,
        perform: @escaping (CloudGatewayMacControllerRequest, @escaping @MainActor (CloudGatewayMacCommandOutcome) -> Void) -> Bool,
        session: @escaping () -> CloudGatewayMacSessionToken? = { nil },
        refresh: @escaping () async -> CloudGatewayMacRefreshResult,
        refreshTimeout: Duration = .seconds(25),
        prepareClient: @escaping () async throws -> CloudGatewayMacPreparedClient,
        setSetupState: @escaping (CloudGatewayMacSetupState) -> Void,
        hasAnyActiveTunnel: @escaping () async throws -> Bool,
        installedIdentity: @escaping () async -> CloudGatewayMacBuildIdentity?,
        installationTimeout: Duration = .seconds(3),
        installationTimer: ((Duration) async throws -> Void)? = nil,
        extensionIdentity: @escaping () throws -> CloudGatewayMacBuildIdentity,
        ping: @escaping (CloudGatewayMacBuildIdentity) async throws -> CloudGatewayMacExtensionVersion?,
        registrationReadiness: @escaping () async -> CloudGatewayMacSetupState = { .required },
        initializeRuntime: @escaping () -> Void = {},
        isRuntimeInitialized: @escaping () -> Bool = { true },
        diagnostics: @escaping () async -> CloudGatewayMacControllerDiagnostics = { .init(runtimeInitialized: false) },
        login: @escaping (CloudGatewayMacControllerRequest) -> CloudGatewayMacLoginStatus? = { _ in nil },
        userActivity: @escaping (Bool) -> Void = { _ in },
        refreshInventoryIfDue: @escaping () -> Void = {},
        setAutomaticInventoryRefreshAllowed: @escaping (Bool, Bool) -> Void = { _, _ in },
        monotonicNow: (() -> Duration)? = nil,
        now: @escaping () -> Date = Date.init,
        managedUpdateObservation: @escaping () async throws -> CloudGatewayMacManagedUpdateObservation = { throw CloudGatewayMacControllerFailure.unavailable },
        reconnectClient: @escaping (String, @escaping @MainActor (CloudGatewayMacCommandOutcome) -> Void) -> Bool = { _, done in done(.failed(.configUnavailable)); return false },
        cancelManagedReconnect: @escaping (String) async -> Void = { _ in },
        activateExtension: @escaping (UUID, CloudGatewayMacBuildIdentity, @escaping @MainActor (CloudGatewayMacExtensionActivationEvent) -> Void) -> Bool = { _, _, _ in false },
        activationIsPending: @escaping () -> Bool = { false }
    ) {
        self.snapshot = snapshot
        self.hasPendingWork = hasPendingWork
        self.perform = perform
        self.session = session
        self.refresh = refresh
        self.refreshTimeout = refreshTimeout
        self.prepareClient = prepareClient
        self.setSetupState = setSetupState
        self.hasAnyActiveTunnel = hasAnyActiveTunnel
        self.installedIdentity = installedIdentity
        self.installationTimeout = installationTimeout
        self.installationTimer = installationTimer ?? { try await Task.sleep(for: $0) }
        self.extensionIdentity = extensionIdentity
        self.ping = ping
        self.registrationReadiness = registrationReadiness
        self.initializeRuntime = initializeRuntime
        self.isRuntimeInitialized = isRuntimeInitialized
        self.diagnostics = diagnostics
        self.login = login
        self.userActivity = userActivity
        self.refreshInventoryIfDue = refreshInventoryIfDue
        self.setAutomaticInventoryRefreshAllowed = setAutomaticInventoryRefreshAllowed
        let clock = ContinuousClock()
        let origin = clock.now
        self.monotonicNow = monotonicNow ?? { origin.duration(to: clock.now) }
        self.now = now
        self.managedUpdateObservation = managedUpdateObservation
        self.reconnectClient = reconnectClient
        self.cancelManagedReconnect = cancelManagedReconnect
        self.activateExtension = activateExtension
        self.activationIsPending = activationIsPending
    }
}

@MainActor
public final class CloudGatewayMacControllerOrchestrator {
    private struct Pending {
        let request: CloudGatewayMacControllerRequest
        let session: CloudGatewayMacSessionToken?
        let deadline: Date
        let preparation: CloudGatewayMacPreparedClient?
    }

    private struct Creation {
        let id: UUID
        let value: CloudGatewayMacPreparedClient
        let expires: Date
    }

    private let effects: CloudGatewayMacControllerEffects
    private let requests: CloudGatewayMacControllerRequests
    private let extensionUpdates: CloudGatewayMacExtensionUpdateOrchestrator
    private let managedUpdates: CloudGatewayMacManagedUpdateWorkflow?
    private var update: CloudGatewayMacUpdateLifecycle
    private var pending: Pending?
    private var pendingCreation: Pending?
    private var preparingManagedUpdate = false
    private var startupReconciliationPending: Bool
    private var pendingLegacyActivationEvent: CloudGatewayMacControllerRequest?
    private var runningOperation: UUID?
    private var runningAction: CloudGatewayMacControllerRequest.Action?
    private var runningCreation: UUID?
    private var creation: Creation?
    private var preparationTask: Task<CloudGatewayMacPreparedClient, any Error>?
    private var preparationId: UUID?
    private var activeRequests = 0
    private var lastActivity: Duration
    private var lastReadiness: Duration?
    private var readinessTask: Task<Void, Never>?
    private var checkingInstallation = false
    private var hasObservedInstallation = false
    private var installationObservation: (id: UUID, reply: InstalledIdentityReply)?
    private var installationReadId: UUID?
    private var extensionIsIdle = false
    private var setupState = CloudGatewayMacSetupState.required

    public init(identity: CloudGatewayMacBuildIdentity, effects: CloudGatewayMacControllerEffects,
                requests: CloudGatewayMacControllerRequests, extensionUpdates: CloudGatewayMacExtensionUpdateOrchestrator,
                managedUpdates: CloudGatewayMacManagedUpdateWorkflow? = nil) {
        self.effects = effects
        self.requests = requests
        self.extensionUpdates = extensionUpdates
        self.managedUpdates = managedUpdates
        startupReconciliationPending = extensionUpdates.hasRestoredAttempt
        managedUpdates?.configure(effects: effects, gate: extensionUpdates, ownerIdentity: identity)
        update = .init(running: identity)
        lastActivity = effects.monotonicNow()
        managedUpdates?.setupStateChanged = { [weak self] in self?.setSetupState($0) }
    }

    public func bootstrapManagedUpdate() async {
        if startupReconciliationPending {
            try? await observeInstallation()
            guard await reconcileStartupAttempt() else {
                if update.isDraining { _ = managedUpdates?.supersede() }
                return
            }
        }
        guard managedUpdates?.isActionable == true else { return }
        effects.initializeRuntime()
        try? await observeInstallation()
        if update.isDraining { _ = managedUpdates?.supersede() }
        else { managedUpdates?.resume() }
    }

    private func reconcileStartupAttempt() async -> Bool {
        guard startupReconciliationPending else { return true }
        guard update.canAcceptMutations, !effects.activationIsPending() else { return false }
        do {
            let owner = managedUpdates?.isBlocked != true && managedUpdates?.isRunning == true
                && managedUpdates?.journal?.appIdentity == update.running
                ? managedUpdates?.journal?.id : nil
            let target = try effects.extensionIdentity()
            if owner == nil, extensionUpdates.state.attempt?.target == target,
               let token = try extensionUpdates.prepareReadiness(target: target) {
                let version = try? await effects.ping(target)
                let ready = version?.bundleShortVersion == target.version && version?.bundleVersion == target.build
                    && version?.codeHash == target.codeHash
                guard try effects.extensionIdentity() == target else { return false }
                _ = try extensionUpdates.reconcileReadiness(token, installedTarget: target,
                                                           authenticatedTarget: ready ? target : nil)
            }
            try extensionUpdates.reconcileRestoredAttempt(target: target, owningAttemptId: owner)
            startupReconciliationPending = false
            return true
        } catch { return false }
    }

    public func authenticationDidChange() {
        managedUpdates?.suppressReconnect()
    }

    public var canExit: Bool {
        if !update.isDraining, startupReconciliationPending || pendingLegacyActivationEvent != nil { return false }
        if update.isDraining, managedUpdates?.isActionable == true { return false }
        if !update.isDraining, managedUpdates?.isActionable == true || effects.activationIsPending() { return false }
        guard activeRequests == 0, pending == nil, runningOperation == nil, pendingCreation == nil, runningCreation == nil,
              !effects.hasPendingWork(), readinessTask == nil, installationObservation == nil else { return false }
        if update.canExit(hasPendingWork: false, activeRequests: 0) { return true }
        // A retained result keeps the controller reachable for its ten-minute recovery window
        return !extensionUpdates.hasPendingAttempt && requests.latest == nil
            && effects.monotonicNow() - lastActivity >= .seconds(900)
    }

    public func tick() async {
        guard !checkingInstallation else { return }
        checkingInstallation = true
        try? await observeInstallation()
        checkingInstallation = false
        retryLegacyActivationEvent()
        managedUpdates?.retryPendingActivationEvent()
        let startupReconciled = await reconcileStartupAttempt()
        if update.isDraining {
            creation = nil
            preparationTask?.cancel()
        }
        if update.isDraining {
            _ = managedUpdates?.supersede()
        } else if startupReconciled { managedUpdates?.resume() }
        expirePending()
        updateInventoryAdmission()
        if canExit { return }
        if startupReconciled, pendingLegacyActivationEvent == nil, update.canAcceptMutations, effects.isRuntimeInitialized() {
            if pending == nil, runningOperation == nil, pendingCreation == nil, runningCreation == nil, preparationTask == nil, managedUpdates?.isActionable != true,
               !extensionUpdates.hasPendingAttempt, readinessTask == nil, !effects.hasPendingWork() {
                effects.refreshInventoryIfDue()
            }
            refreshReadiness(force: false)
        }
    }

    public func handle(_ request: CloudGatewayMacControllerRequest) async -> CloudGatewayMacControllerReply {
        activeRequests += 1
        defer { activeRequests -= 1 }
        expirePending()
        managedUpdates?.expirePrepared()
        updateInventoryAdmission()
        // Lifecycle and doctor probes must leave a cold Firebase runtime untouched
        if request.action != .lifecycle && request.action != .diagnostics {
            let wasInitialized = effects.isRuntimeInitialized()
            effects.initializeRuntime()
            if !wasInitialized, update.canAcceptMutations {
                setSetupState(.checkingConnection)
                refreshReadiness()
            }
        }
        let activity: Set<CloudGatewayMacControllerRequest.Action> = [
            .userActivity, .recordActivity, .menuWillOpen, .connect, .turnOff, .disconnectClient, .signIn, .cancelSignIn, .signOut,
            .refresh, .awaitRefresh, .prepareClient, .createClient, .removeClient, .beginLogin, .cancelLogin, .update
        ]
        if activity.contains(request.action), update.canAcceptMutations || request.action == .turnOff {
            lastActivity = effects.monotonicNow()
            effects.userActivity(request.action == .userActivity)
        }
        if request.action == .removeClient,
           request.buildIdentity != update.running || request.appVersion != update.running.version || request.appBuild != update.running.build {
            return .init(error: .incompatibleVersion)
        }
        switch request.action {
        case .lifecycle:
            if !hasObservedInstallation {
                do { try await observeInstallation() }
                catch { return .init(error: .timeout) }
            }
            return .init(lifecycle: .init(running: update.running, installed: update.installed,
                                         state: update.isDraining ? .draining : update.installed == nil ? .invalidInstallation : .current))
        case .diagnostics: return .init(diagnostics: (await effects.diagnostics()).withSetupState(setupState))
        case .beginLogin, .loginStatus, .cancelLogin:
            if request.action == .beginLogin, !update.canAcceptMutations || startupReconciliationPending
                || pendingLegacyActivationEvent != nil || managedUpdates?.isActionable == true || effects.activationIsPending() {
                return .init(error: .busy)
            }
            if request.action == .cancelLogin { managedUpdates?.suppressReconnect() }
            guard let login = effects.login(request) else { return .init(error: .invalidRequest) }
            return .init(login: login)
        case .status: return controlReply(for: request)
        case .operation:
            guard let id = request.contextId else { return .init(error: .invalidRequest) }
            if managedUpdates?.owns(id) == true { return managedReply(for: request) }
            return controlReply(for: request, operation: requests.operation(id: id))
        case .confirmOperation:
            if let id = request.contextId, managedUpdates?.owns(id) == true {
                guard request.buildIdentity == update.running, update.canAcceptMutations else { return .init(error: .incompatibleVersion) }
                await managedUpdates?.confirm(id)
                return managedReply(for: request)
            }
            return confirm(request)
        default: break
        }
        let callbacks: Set<CloudGatewayMacControllerRequest.Action> = [
            .extensionUpdateStarted, .extensionUpdateApproval, .extensionUpdateRestart, .extensionUpdateFinished, .extensionUpdateFailed
        ]
        guard update.canAcceptMutations || request.action == .snapshot || request.action == .turnOff
            || callbacks.contains(request.action) else { return .init(error: .busy) }
        let revoking: Set<CloudGatewayMacControllerRequest.Action> = [.turnOff, .disconnectClient, .signOut, .cancelSignIn, .cancelLogin]
        if startupReconciliationPending || pendingLegacyActivationEvent != nil || preparingManagedUpdate
            || managedUpdates?.isActionable == true || effects.activationIsPending() {
            let readable: Set<CloudGatewayMacControllerRequest.Action> = [.snapshot, .userActivity, .recordActivity, .menuWillOpen]
            guard revoking.contains(request.action) || readable.contains(request.action) || callbacks.contains(request.action)
                    || request.action == .update else { return .init(error: .busy) }
        }
        if request.action == .update {
            if managedUpdates?.owns(request.id) == true, let managedUpdates {
                let status = await managedUpdates.reserve(request, fallbackTarget: update.running)
                return .init(state: frontendSnapshot(canUpdateExtension: false), operation: status.operation,
                             accepted: status.phase != .failed && status.phase != .superseded,
                             operationId: status.id, update: status)
            }
            guard !startupReconciliationPending, pendingLegacyActivationEvent == nil,
                  !preparingManagedUpdate, pending == nil, runningOperation == nil, pendingCreation == nil, runningCreation == nil, preparationTask == nil,
                  let managedUpdates else { return .init(error: .busy) }
            preparingManagedUpdate = true
            defer { preparingManagedUpdate = false; updateInventoryAdmission() }
            let status = await managedUpdates.reserve(request, fallbackTarget: update.running)
            return .init(state: frontendSnapshot(canUpdateExtension: false), operation: status.operation,
                         accepted: status.phase != .failed && status.phase != .superseded,
                         operationId: status.id, update: status)
        }
        if request.action.requiresConfirmation { return admit(request) }
        switch request.action {
        case .snapshot: return reply()
        case .userActivity, .recordActivity: return reply()
        case .prepareClient: return await prepareClient()
        case .prepareExtensionUpdate: return await prepareExtensionUpdate()
        case .extensionUpdateStarted, .extensionUpdateApproval, .extensionUpdateRestart, .extensionUpdateFinished, .extensionUpdateFailed:
            return reportExtensionUpdate(request)
        case .refresh, .menuWillOpen:
            if request.action == .refresh, pendingCreation != nil || runningCreation != nil { return .init(error: .busy) }
            _ = effects.perform(request, { _ in })
            refreshReadiness()
            return reply()
        case .awaitRefresh:
            guard pendingCreation == nil, runningCreation == nil else { return .init(error: .busy) }
            refreshReadiness()
            let result = try? await CloudGatewayMacInventoryRequest.read(
                timeout: effects.refreshTimeout, onTimeout: { .success(.timedOut) }
            ) { [effects] complete in
                let task = Task { complete(.success(await effects.refresh())) }
                return { task.cancel() }
            }
            return reply(refresh: result ?? .superseded)
        default: return .init(error: .invalidRequest)
        }
    }

    private func observeInstallation() async throws {
        let observation: (id: UUID, reply: InstalledIdentityReply)
        if let existing = installationObservation { observation = existing }
        else {
            // Native signature validation keeps its slot until it returns, even after the reply deadline
            guard installationReadId == nil else { throw CloudGatewayMacControllerFailure.timeout }
            observation = (UUID(), InstalledIdentityReply())
            installationObservation = observation
            installationReadId = observation.id
            startInstallationObservation(id: observation.id, reply: observation.reply)
        }
        _ = try await observation.reply.value().get()
    }

    private func startInstallationObservation(id: UUID, reply: InstalledIdentityReply) {
        let installedIdentity = effects.installedIdentity
        Task { [weak self] in
            let installed = await installedIdentity()
            guard let self, installationReadId == id else { return }
            installationReadId = nil
            finishInstallationObservation(id: id, result: .success(installed))
        }
        let installationTimer = effects.installationTimer
        let timeout = effects.installationTimeout
        reply.timer = Task { [weak self] in
            do { try await installationTimer(timeout) } catch { return }
            self?.finishInstallationObservation(id: id, result: .failure(.timeout))
        }
    }

    private func finishInstallationObservation(id: UUID, result: InstalledIdentityReply.Reply) {
        guard let observation = installationObservation, observation.id == id else { return }
        installationObservation = nil
        if case .success(let installed) = result {
            update.observe(installed)
            hasObservedInstallation = true
        }
        observation.reply.finish(result)
    }

    private func admit(_ request: CloudGatewayMacControllerRequest) -> CloudGatewayMacControllerReply {
        defer { updateInventoryAdmission() }
        do {
            guard managedUpdates?.owns(request.id) != true else { return .init(error: .invalidRequest) }
            if let operation = try requests.lookup(request) {
                return operationReply(operation, request: request)
            }
            guard !preparingManagedUpdate else { return .init(error: .busy) }
            let isStop = request.action == .turnOff || request.action == .disconnectClient
            if request.action == .createClient {
                guard pendingCreation == nil, runningCreation == nil,
                      pending == nil || pending?.request.action == .turnOff || pending?.request.action == .disconnectClient,
                      runningOperation == nil || runningAction == .turnOff || runningAction == .disconnectClient else {
                    return .init(error: .busy)
                }
            } else {
                guard pending == nil, runningOperation == nil,
                      isStop || pendingCreation == nil && runningCreation == nil else { return .init(error: .busy) }
            }
            if request.action == .removeClient {
                guard canAdmitRemoval else { return .init(error: .busy) }
                guard removalSessionIsSettled(request) else { return .init(error: .rejected) }
            }
            if request.action == .disconnectClient {
                let snapshot = effects.snapshot(setupState, false)
                guard let session = effects.session(), session.accountId == snapshot.accountId,
                      snapshot.accessAuthorized, !snapshot.isRestoringSession, !snapshot.isAuthSettling,
                      let identifier = request.identifier,
                      snapshot.clients.filter({ $0.identifier == identifier }).count == 1 else {
                    return .init(error: .rejected)
                }
            }
            var prepared: CloudGatewayMacPreparedClient?
            if request.action == .createClient {
                guard let creation, creation.id == request.contextId, creation.expires > effects.now() else {
                    return .init(error: .preparationExpired)
                }
                prepared = creation.value
            }
            let operation = try requests.accept(request)
            let reservation = Pending(request: request, session: effects.session(),
                                      deadline: effects.now().addingTimeInterval(30), preparation: prepared)
            if request.action == .createClient { pendingCreation = reservation }
            else { pending = reservation }
            return operationReply(operation, request: request)
        } catch { return .init(error: error as? CloudGatewayMacControllerFailure ?? .unavailable) }
    }

    private var canAdmitRemoval: Bool {
        update.canAcceptMutations && !startupReconciliationPending && pendingLegacyActivationEvent == nil
            && !preparingManagedUpdate && managedUpdates?.isActionable != true
            && !extensionUpdates.hasPendingAttempt && !effects.activationIsPending()
            && preparationTask == nil && !effects.hasPendingWork()
    }

    private func removalSessionIsSettled(_ request: CloudGatewayMacControllerRequest) -> Bool {
        let snapshot = effects.snapshot(setupState, false)
        guard let session = effects.session(), session.accountId == snapshot.accountId,
              snapshot.accessAuthorized, !snapshot.isRestoringSession, !snapshot.isAuthSettling,
              let identifier = request.identifier else { return false }
        return identifier.split(separator: "/").first == Substring(session.accountId)
    }

    private func confirm(_ confirmation: CloudGatewayMacControllerRequest) -> CloudGatewayMacControllerReply {
        defer { updateInventoryAdmission() }
        guard let id = confirmation.contextId else { return .init(error: .invalidRequest) }
        guard let pending = [pendingCreation, pending].compactMap({ $0 }).first(where: { $0.request.id == id }) else {
            return controlReply(for: confirmation, operation: requests.operation(id: id))
        }
        let request = pending.request
        let session = effects.session()
        guard request.action == .turnOff || (update.canAcceptMutations && confirmation.buildIdentity == update.running) else {
            clearPending(id: id)
            return controlReply(for: confirmation, operation: requests.finish(
                id: id, state: .failed, failure: .incompatibleVersion, outcome: .failed(.incompatibleVersion), session: pending.session
            ))
        }
        // Account work runs only for the session that reserved it
        if request.action.hasAccountBoundOutcome, session != pending.session {
            clearPending(id: id)
            return controlReply(for: confirmation, operation: requests.finish(
                id: id, state: .failed, failure: .rejected, outcome: .failed(.signInRequired), session: pending.session
            ))
        }
        if request.action == .removeClient {
            let failure: CloudGatewayMacCommandFailure? = if !canAdmitRemoval { .busy }
                else if !removalSessionIsSettled(request) { .signInRequired }
                else if confirmation.appVersion != update.running.version || confirmation.appBuild != update.running.build { .incompatibleVersion }
                else { nil }
            if let failure {
                clearPending(id: id)
                return controlReply(for: confirmation, operation: requests.finish(
                    id: id, state: .failed, failure: failure == .busy ? .busy : .rejected,
                    outcome: .failed(failure), session: pending.session
                ))
            }
        }
        if request.action == .disconnectClient {
            let snapshot = effects.snapshot(setupState, false)
            guard session != nil, session?.accountId == snapshot.accountId, snapshot.accessAuthorized,
                  let identifier = request.identifier,
                  snapshot.clients.filter({ $0.identifier == identifier }).count == 1 else {
                clearPending(id: id)
                return controlReply(for: confirmation, operation: requests.finish(
                    id: id, state: .failed, failure: .rejected, outcome: .failed(.configUnavailable), session: pending.session
                ))
            }
        }
        if request.action == .createClient,
           creation?.id != request.contextId || creation.map({ $0.expires <= effects.now() }) != false {
            clearPending(id: id)
            return controlReply(for: confirmation, operation: requests.finish(id: id, state: .failed, failure: .preparationExpired))
        }
        if suppressesManagedReconnect(request) { managedUpdates?.suppressReconnect() }
        clearPending(id: id)
        if request.action == .createClient { runningCreation = id }
        else { runningOperation = id; runningAction = request.action }
        updateInventoryAdmission()
        requests.finish(id: id, state: .running)
        // Effects may reject synchronously before returning their admission result
        var submitting = true
        var heldOutcome: CloudGatewayMacCommandOutcome?
        let completion: @MainActor (CloudGatewayMacCommandOutcome) -> Void = { [weak self] outcome in
            guard let self, isRunning(id: id) else { return }
            // A command that refuses work reports why before returning false
            if submitting { heldOutcome = outcome }
            else { record(outcome, of: request, session: session, rejected: false) }
        }
        let accepted: Bool
        if request.action == .createClient, let prepared = pending.preparation,
           let region = request.regionId, let name = request.clientName {
            creation = nil
            accepted = prepared.submit(region, name, completion)
        } else {
            if request.action == .signOut || request.action == .cancelSignIn { creation = nil }
            accepted = effects.perform(request, completion)
        }
        submitting = false
        if let held = heldOutcome {
            record(held, of: request, session: session, rejected: !accepted)
        } else if !accepted, isRunning(id: id) {
            requests.finish(id: id, state: .failed, failure: .rejected)
            clearRunning(id: id)
        }
        return controlReply(for: confirmation, operation: requests.operation(id: id))
    }

    private func suppressesManagedReconnect(_ request: CloudGatewayMacControllerRequest) -> Bool {
        switch request.action {
        case .turnOff, .signOut, .cancelSignIn: true
        case .disconnectClient: request.identifier == managedUpdates?.journal?.identifier
        default: false
        }
    }

    private func record(_ outcome: CloudGatewayMacCommandOutcome, of request: CloudGatewayMacControllerRequest,
                        session: CloudGatewayMacSessionToken?, rejected: Bool) {
        let recorded: CloudGatewayMacCommandOutcome
        let suppressionNotPersisted = suppressesManagedReconnect(request) && managedUpdates?.journal?.warning == .storageUnavailable
        let warning: CloudGatewayMacCommandWarning?
        if case .completed = outcome, suppressionNotPersisted {
            recorded = .completed(warning: .reconnectSuppressionNotPersisted)
            warning = nil
        } else {
            recorded = outcome
            warning = suppressionNotPersisted ? .reconnectSuppressionNotPersisted : nil
        }
        var failure: CloudGatewayMacControllerFailure?
        if outcome.state == .failed, case .failed(let reason) = outcome {
            failure = reason == .busy ? .busy : rejected ? .rejected
                : request.action == .signOut ? .authCleanupFailed : .commandFailed
        }
        _ = requests.finish(id: request.id, state: recorded.state, failure: failure, warning: warning,
                            outcome: recorded, session: session)
        clearRunning(id: request.id)
        updateInventoryAdmission()
    }

    private func isRunning(id: UUID) -> Bool {
        runningCreation == id || runningOperation == id
    }

    private func clearRunning(id: UUID) {
        if runningCreation == id { runningCreation = nil }
        if runningOperation == id { runningOperation = nil; runningAction = nil }
    }

    private func clearPending(id: UUID) {
        if pendingCreation?.request.id == id { pendingCreation = nil }
        if pending?.request.id == id { pending = nil }
    }

    private func expirePending() {
        for reservation in [pendingCreation, pending].compactMap({ $0 }) where reservation.deadline <= effects.now() {
            _ = requests.finish(id: reservation.request.id, state: .unknown, outcome: .expired, session: reservation.session)
            clearPending(id: reservation.request.id)
        }
    }

    private func prepareClient() async -> CloudGatewayMacControllerReply {
        guard preparationTask == nil, pending == nil, runningOperation == nil, pendingCreation == nil, runningCreation == nil else { return .init(error: .busy) }
        let id = UUID()
        preparationId = id
        let task = Task {
            try await CloudGatewayMacInventoryRequest.perform(timeout: .seconds(22)) { [effects] in
                try await effects.prepareClient()
            }
        }
        preparationTask = task
        updateInventoryAdmission()
        defer {
            if preparationId == id { preparationTask = nil; preparationId = nil }
            updateInventoryAdmission()
        }
        do {
            let prepared = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard update.canAcceptMutations, preparationId == id else { return .init(error: .preparationExpired) }
            creation = Creation(id: id, value: prepared, expires: effects.now().addingTimeInterval(300))
            return .init(creation: .init(id: id, regions: prepared.regions))
        } catch {
            return .init(error: error is CancellationError ? .preparationExpired : .unavailable)
        }
    }

    private func operationReply(_ operation: CloudGatewayMacControllerOperation,
                                request: CloudGatewayMacControllerRequest) -> CloudGatewayMacControllerReply {
        if request.action == .turnOff { return controlReply(for: request, operation: operation) }
        return reply(operation: operation)
    }

    private func controlReply(for request: CloudGatewayMacControllerRequest,
                              operation: CloudGatewayMacControllerOperation? = nil) -> CloudGatewayMacControllerReply {
        var operation = operation ?? requests.latest ?? managedUpdates?.operation
        let snapshot = frontendSnapshot(canUpdateExtension: false)
        // Other builds may not decode newer outcome cases, so they get the compatible operation only
        let sameBuild = request.buildIdentity == update.running
            && request.appVersion == update.running.version && request.appBuild == update.running.build
        if !sameBuild, let current = operation, current.warning == .localCleanupIncomplete {
            operation = .init(id: current.id, state: current.state, failure: current.failure)
        }
        let outcome = sameBuild ? operation.flatMap {
            requests.outcome(id: $0.id, session: effects.session())
        } : nil
        var managedStatus = sameBuild ? managedUpdates?.status(accountId: effects.session()?.accountId) : nil
        if request.action == .operation || request.action == .confirmOperation, managedStatus?.id != request.contextId {
            managedStatus = nil
        }
        return .init(state: request.action == .operation && sameBuild ? snapshot : nil,
                     status: snapshot.status, operation: operation, outcome: outcome,
                     accepted: operation.map { $0.state != .failed && $0.state != .unknown }, operationId: operation?.id,
                     update: managedStatus)
    }

    private func managedReply(for request: CloudGatewayMacControllerRequest) -> CloudGatewayMacControllerReply {
        controlReply(for: request, operation: managedUpdates?.operation)
    }

    private func reply(operation: CloudGatewayMacControllerOperation? = nil,
                       refresh: CloudGatewayMacRefreshResult? = nil) -> CloudGatewayMacControllerReply {
        let operation = operation ?? requests.latest ?? managedUpdates?.operation
        return .init(state: frontendSnapshot(canUpdateExtension: extensionIsIdle && !extensionUpdates.hasPendingAttempt && readinessTask == nil && pending == nil && runningOperation == nil && pendingCreation == nil && runningCreation == nil
                                              && !effects.hasPendingWork() && update.canAcceptMutations && managedUpdates?.isActionable != true
                                              && managedUpdates?.isBlocked != true && !effects.activationIsPending()
                                              && !startupReconciliationPending && pendingLegacyActivationEvent == nil),
              operation: operation, outcome: operation.flatMap { requests.outcome(id: $0.id, session: effects.session()) },
              refresh: refresh, accepted: operation.map { $0.state != .failed && $0.state != .unknown }, operationId: operation?.id,
              update: managedUpdates?.status(accountId: effects.session()?.accountId))
    }

    private func frontendSnapshot(canUpdateExtension: Bool) -> CloudGatewayMacControllerState {
        var snapshot = effects.snapshot(setupState, canUpdateExtension)
        snapshot.removalAllowed = canAdmitRemoval && pending == nil && runningOperation == nil
        return snapshot
    }

    private func setSetupState(_ state: CloudGatewayMacSetupState) {
        setupState = state
        effects.setSetupState(state)
    }

    private func prepareExtensionUpdate() async -> CloudGatewayMacControllerReply {
        guard !startupReconciliationPending, pendingLegacyActivationEvent == nil,
              !preparingManagedUpdate, managedUpdates?.isActionable != true, managedUpdates?.isBlocked != true,
              !effects.activationIsPending(),
              !extensionUpdates.hasPendingAttempt, !effects.hasPendingWork(), readinessTask == nil,
              pending == nil, runningOperation == nil, pendingCreation == nil, runningCreation == nil else { return .init(error: .busy) }
        var attempt: CloudGatewayMacExtensionUpdateOrchestrator.Attempt?
        do {
            let target = try effects.extensionIdentity()
            let reserved = try extensionUpdates.begin(target: target)
            updateInventoryAdmission()
            attempt = reserved
            setSetupState(.activating)
            guard try await !effects.hasAnyActiveTunnel(), update.canAcceptMutations,
                  try effects.extensionIdentity() == target else { throw CloudGatewayMacControllerFailure.busy }
            if managedUpdates != nil {
                try extensionUpdates.handle(.started, attemptId: reserved.id, installedTarget: target)
                let accepted = effects.activateExtension(reserved.id, target) { [weak self] event in
                    guard let self else { return }
                    let action: CloudGatewayMacControllerRequest.Action
                    switch event {
                    case .approvalRequired: action = .extensionUpdateApproval
                    case .restartRequired: action = .extensionUpdateRestart
                    case .completed: action = .extensionUpdateFinished
                    case .failed: action = .extensionUpdateFailed
                    }
                    _ = reportExtensionUpdate(.init(action: action, contextId: reserved.id))
                }
                guard accepted else { throw CloudGatewayMacControllerFailure.unavailable }
            }
            return .init(accepted: true, operationId: reserved.id, extensionTarget: target)
        } catch {
            if let attempt { try? extensionUpdates.handle(.failed, attemptId: attempt.id, installedTarget: attempt.target) }
            updateInventoryAdmission()
            setSetupState(extensionUpdates.setupState ?? .updateRequired)
            return .init(error: error as? CloudGatewayMacControllerFailure ?? .unavailable)
        }
    }

    private func reportExtensionUpdate(_ request: CloudGatewayMacControllerRequest) -> CloudGatewayMacControllerReply {
        guard let id = request.contextId else { return .init(error: .invalidRequest) }
        let event: CloudGatewayMacExtensionUpdateOrchestrator.Event
        switch request.action {
        case .extensionUpdateStarted: event = .started
        case .extensionUpdateApproval: event = .approval
        case .extensionUpdateRestart: event = .rebootRequired
        case .extensionUpdateFinished: event = .finished
        case .extensionUpdateFailed: event = .failed
        default: return .init(error: .invalidRequest)
        }
        if managedUpdates?.owns(id) == true { return .init(error: .extensionAttemptChanged) }
        do {
            try extensionUpdates.handle(event, attemptId: id, installedTarget: effects.extensionIdentity(),
                                        canSubmit: update.canAcceptMutations)
            if pendingLegacyActivationEvent?.contextId == id,
               pendingLegacyActivationEvent?.action == request.action || event != .approval {
                pendingLegacyActivationEvent = nil
            }
            updateInventoryAdmission()
            setSetupState(extensionUpdates.setupState ?? .checkingConnection)
            refreshReadiness()
            return .init(accepted: true)
        } catch {
            if error as? CloudGatewayMacControllerFailure == .rejected {
                if pendingLegacyActivationEvent?.contextId == id { pendingLegacyActivationEvent = nil }
                return .init(error: .extensionAttemptChanged)
            }
            if event != .started,
               pendingLegacyActivationEvent == nil || pendingLegacyActivationEvent?.action == .extensionUpdateApproval {
                pendingLegacyActivationEvent = request
            }
            return .init(error: .unavailable)
        }
    }

    private func retryLegacyActivationEvent() {
        guard let request = pendingLegacyActivationEvent else { return }
        _ = reportExtensionUpdate(request)
    }

    private func refreshReadiness(force: Bool = true) {
        guard !startupReconciliationPending, pendingLegacyActivationEvent == nil,
              readinessTask == nil, managedUpdates?.isRunning != true,
              pending == nil, runningOperation == nil, pendingCreation == nil, runningCreation == nil,
              preparationTask == nil else { return }
        let now = effects.monotonicNow()
        let interval: Duration = extensionUpdates.hasPendingAttempt ? .seconds(5) : .seconds(60)
        if !force, let lastReadiness, now - lastReadiness < interval { return }
        lastReadiness = now
        let identity: CloudGatewayMacBuildIdentity
        let token: CloudGatewayMacExtensionUpdateOrchestrator.ReadinessToken
        do {
            identity = try effects.extensionIdentity()
            guard let permitted = try extensionUpdates.prepareReadiness(target: identity) else {
                setSetupState(extensionUpdates.setupState ?? .updateRequired)
                return
            }
            token = permitted
        } catch { setSetupState(.invalidBundle); return }
        if extensionUpdates.hasPendingAttempt { setSetupState(extensionUpdates.setupState ?? .checkingConnection) }
        readinessTask = Task { [weak self] in
            guard let self else { return }
            defer { readinessTask = nil; updateInventoryAdmission() }
            extensionIsIdle = (try? await !effects.hasAnyActiveTunnel()) == true
            let running = try? await effects.ping(identity)
            let observed = running.flatMap { version -> CloudGatewayMacBuildIdentity? in
                guard let hash = version.codeHash else { return nil }
                return CloudGatewayMacBuildIdentity(version: version.bundleShortVersion, build: version.bundleVersion, codeHash: hash)
            }
            do {
                let result = try extensionUpdates.reconcileReadiness(token, installedTarget: effects.extensionIdentity(),
                                                                    authenticatedTarget: observed)
                switch result {
                case .ignored: return
                case .ready: setSetupState(.ready)
                case .notReady:
                    if extensionUpdates.hasPendingAttempt { setSetupState(extensionUpdates.setupState ?? .checkingConnection) }
                    else if running != nil { setSetupState(.updateRequired) }
                    else {
                        let registration = await effects.registrationReadiness()
                        guard !extensionUpdates.hasPendingAttempt, try effects.extensionIdentity() == identity else { return }
                        setSetupState(registration)
                    }
                }
            } catch { setSetupState(.unavailable) }
        }
    }

    private func updateInventoryAdmission() {
        effects.setAutomaticInventoryRefreshAllowed(
            update.canAcceptMutations && !startupReconciliationPending && pendingLegacyActivationEvent == nil
                && pending == nil && runningOperation == nil && pendingCreation == nil && runningCreation == nil
                && preparationTask == nil && !preparingManagedUpdate && !extensionUpdates.hasPendingAttempt && managedUpdates?.isActionable != true,
            update.isDraining
        )
    }
}

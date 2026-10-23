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
        now: @escaping () -> Date = Date.init
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
    private var update: CloudGatewayMacUpdateLifecycle
    private var pending: Pending?
    private var runningOperation: UUID?
    // Valid because confirm hands work to effects synchronously, without suspending
    private var submitting: UUID?
    private var heldOutcome: CloudGatewayMacCommandOutcome?
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
                requests: CloudGatewayMacControllerRequests, extensionUpdates: CloudGatewayMacExtensionUpdateOrchestrator) {
        self.effects = effects
        self.requests = requests
        self.extensionUpdates = extensionUpdates
        update = .init(running: identity)
        lastActivity = effects.monotonicNow()
    }

    public var canExit: Bool {
        guard activeRequests == 0, pending == nil, runningOperation == nil,
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
        if update.isDraining {
            creation = nil
            preparationTask?.cancel()
        }
        expirePending()
        updateInventoryAdmission()
        if canExit { return }
        if update.canAcceptMutations, effects.isRuntimeInitialized() {
            if pending == nil, runningOperation == nil, preparationTask == nil,
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
            .refresh, .awaitRefresh, .prepareClient, .createClient, .beginLogin, .cancelLogin
        ]
        if activity.contains(request.action), update.canAcceptMutations || request.action == .turnOff {
            lastActivity = effects.monotonicNow()
            effects.userActivity(request.action == .userActivity)
        }
        switch request.action {
        case .lifecycle:
            if !hasObservedInstallation {
                do { try await observeInstallation() }
                catch { return .init(error: .timeout) }
            }
            return .init(lifecycle: .init(running: update.running, installed: update.installed,
                                         state: update.isDraining ? .draining : update.installed == nil ? .invalidInstallation : .current))
        case .diagnostics: return .init(diagnostics: await effects.diagnostics())
        case .beginLogin, .loginStatus, .cancelLogin:
            if request.action == .beginLogin, !update.canAcceptMutations { return .init(error: .busy) }
            guard let login = effects.login(request) else { return .init(error: .invalidRequest) }
            return .init(login: login)
        case .status: return controlReply(for: request)
        case .operation:
            guard let id = request.contextId else { return .init(error: .invalidRequest) }
            return controlReply(for: request, operation: requests.operation(id: id))
        case .confirmOperation: return confirm(request)
        default: break
        }
        let callbacks: Set<CloudGatewayMacControllerRequest.Action> = [
            .extensionUpdateStarted, .extensionUpdateApproval, .extensionUpdateRestart, .extensionUpdateFinished, .extensionUpdateFailed
        ]
        guard update.canAcceptMutations || request.action == .snapshot || request.action == .turnOff
            || callbacks.contains(request.action) else { return .init(error: .busy) }
        if request.action.requiresConfirmation { return admit(request) }
        switch request.action {
        case .snapshot: return reply()
        case .userActivity, .recordActivity: return reply()
        case .prepareClient: return await prepareClient()
        case .prepareExtensionUpdate: return await prepareExtensionUpdate()
        case .extensionUpdateStarted, .extensionUpdateApproval, .extensionUpdateRestart, .extensionUpdateFinished, .extensionUpdateFailed:
            return reportExtensionUpdate(request)
        case .refresh, .menuWillOpen:
            _ = effects.perform(request, { _ in })
            refreshReadiness()
            return reply()
        case .awaitRefresh:
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
            if let operation = try requests.lookup(request) {
                return operationReply(operation, request: request)
            }
            guard pending == nil, runningOperation == nil else { return .init(error: .busy) }
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
            pending = Pending(request: request, session: effects.session(),
                              deadline: effects.now().addingTimeInterval(30), preparation: prepared)
            return operationReply(operation, request: request)
        } catch { return .init(error: error as? CloudGatewayMacControllerFailure ?? .unavailable) }
    }

    private func confirm(_ confirmation: CloudGatewayMacControllerRequest) -> CloudGatewayMacControllerReply {
        defer { updateInventoryAdmission() }
        guard let id = confirmation.contextId else { return .init(error: .invalidRequest) }
        guard let pending, pending.request.id == id else {
            return controlReply(for: confirmation, operation: requests.operation(id: id))
        }
        let request = pending.request
        let session = effects.session()
        guard request.action == .turnOff || (update.canAcceptMutations && confirmation.buildIdentity == update.running) else {
            self.pending = nil
            return controlReply(for: confirmation, operation: requests.finish(
                id: id, state: .failed, failure: .incompatibleVersion, outcome: .failed(.incompatibleVersion), session: pending.session
            ))
        }
        // Account work runs only for the session that reserved it
        if request.action.hasAccountBoundOutcome, session != pending.session {
            self.pending = nil
            return controlReply(for: confirmation, operation: requests.finish(
                id: id, state: .failed, failure: .rejected, outcome: .failed(.signInRequired), session: pending.session
            ))
        }
        if request.action == .disconnectClient {
            let snapshot = effects.snapshot(setupState, false)
            guard session != nil, session?.accountId == snapshot.accountId, snapshot.accessAuthorized,
                  let identifier = request.identifier,
                  snapshot.clients.filter({ $0.identifier == identifier }).count == 1 else {
                self.pending = nil
                return controlReply(for: confirmation, operation: requests.finish(
                    id: id, state: .failed, failure: .rejected, outcome: .failed(.configUnavailable), session: pending.session
                ))
            }
        }
        if request.action == .createClient,
           creation?.id != request.contextId || creation.map({ $0.expires <= effects.now() }) != false {
            self.pending = nil
            return controlReply(for: confirmation, operation: requests.finish(id: id, state: .failed, failure: .preparationExpired))
        }
        self.pending = nil
        runningOperation = id
        updateInventoryAdmission()
        requests.finish(id: id, state: .running)
        submitting = id
        let completion: @MainActor (CloudGatewayMacCommandOutcome) -> Void = { [weak self] outcome in
            guard let self, runningOperation == id else { return }
            // A command that refuses work reports why before returning false
            if submitting == id { heldOutcome = outcome }
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
        submitting = nil
        if let held = heldOutcome {
            heldOutcome = nil
            record(held, of: request, session: session, rejected: !accepted)
        } else if !accepted, runningOperation == id {
            requests.finish(id: id, state: .failed, failure: .rejected)
            runningOperation = nil
        }
        return controlReply(for: confirmation, operation: requests.operation(id: id))
    }

    private func record(_ outcome: CloudGatewayMacCommandOutcome, of request: CloudGatewayMacControllerRequest,
                        session: CloudGatewayMacSessionToken?, rejected: Bool) {
        var failure: CloudGatewayMacControllerFailure?
        if outcome.state == .failed, case .failed(let reason) = outcome {
            failure = reason == .busy ? .busy : rejected ? .rejected
                : request.action == .signOut ? .authCleanupFailed : .commandFailed
        }
        _ = requests.finish(id: request.id, state: outcome.state, failure: failure, outcome: outcome, session: session)
        runningOperation = nil
        updateInventoryAdmission()
    }

    private func expirePending() {
        guard let pending, pending.deadline <= effects.now() else { return }
        _ = requests.finish(id: pending.request.id, state: .unknown, outcome: .expired, session: pending.session)
        self.pending = nil
    }

    private func prepareClient() async -> CloudGatewayMacControllerReply {
        guard preparationTask == nil, pending == nil, runningOperation == nil else { return .init(error: .busy) }
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
        let operation = operation ?? requests.latest
        let snapshot = effects.snapshot(setupState, false)
        // Other builds may not decode newer outcome cases, so they get the compatible operation only
        let sameBuild = request.buildIdentity == update.running
            && request.appVersion == update.running.version && request.appBuild == update.running.build
        let outcome = sameBuild ? operation.flatMap {
            requests.outcome(id: $0.id, session: effects.session())
        } : nil
        return .init(state: request.action == .operation && sameBuild ? snapshot : nil,
                     status: snapshot.status, operation: operation, outcome: outcome,
                     accepted: operation.map { $0.state != .failed && $0.state != .unknown }, operationId: operation?.id)
    }

    private func reply(operation: CloudGatewayMacControllerOperation? = nil,
                       refresh: CloudGatewayMacRefreshResult? = nil) -> CloudGatewayMacControllerReply {
        let operation = operation ?? requests.latest
        return .init(state: effects.snapshot(setupState, extensionIsIdle && !extensionUpdates.hasPendingAttempt && readinessTask == nil && pending == nil && runningOperation == nil
                                              && !effects.hasPendingWork() && update.canAcceptMutations),
              operation: operation, outcome: operation.flatMap { requests.outcome(id: $0.id, session: effects.session()) },
              refresh: refresh, accepted: operation.map { $0.state != .failed && $0.state != .unknown }, operationId: operation?.id)
    }

    private func setSetupState(_ state: CloudGatewayMacSetupState) {
        setupState = state
        effects.setSetupState(state)
    }

    private func prepareExtensionUpdate() async -> CloudGatewayMacControllerReply {
        guard !extensionUpdates.hasPendingAttempt, !effects.hasPendingWork(), readinessTask == nil,
              pending == nil, runningOperation == nil else { return .init(error: .busy) }
        var attempt: CloudGatewayMacExtensionUpdateOrchestrator.Attempt?
        do {
            let target = try effects.extensionIdentity()
            let reserved = try extensionUpdates.begin(target: target)
            updateInventoryAdmission()
            attempt = reserved
            setSetupState(.activating)
            guard try await !effects.hasAnyActiveTunnel(), update.canAcceptMutations,
                  try effects.extensionIdentity() == target else { throw CloudGatewayMacControllerFailure.busy }
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
        do {
            try extensionUpdates.handle(event, attemptId: id, installedTarget: effects.extensionIdentity(),
                                        canSubmit: update.canAcceptMutations)
            updateInventoryAdmission()
            setSetupState(extensionUpdates.setupState ?? .checkingConnection)
            refreshReadiness()
            return .init(accepted: true)
        } catch {
            return .init(error: error as? CloudGatewayMacControllerFailure == .rejected ? .extensionAttemptChanged : .unavailable)
        }
    }

    private func refreshReadiness(force: Bool = true) {
        guard readinessTask == nil else { return }
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
            update.canAcceptMutations && pending == nil && runningOperation == nil
                && preparationTask == nil && !extensionUpdates.hasPendingAttempt,
            update.isDraining
        )
    }
}

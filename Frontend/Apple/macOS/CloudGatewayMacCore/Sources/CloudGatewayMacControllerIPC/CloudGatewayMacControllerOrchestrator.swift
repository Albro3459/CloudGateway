import CloudGatewayKit
import CloudGatewayMacCore
import CloudGatewayMacIPC
import Foundation

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
    let extensionIdentity: () throws -> CloudGatewayMacBuildIdentity
    let ping: (CloudGatewayMacBuildIdentity) async throws -> CloudGatewayMacExtensionVersion?
    let registrationReadiness: () async -> CloudGatewayMacSetupState
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
        extensionIdentity: @escaping () throws -> CloudGatewayMacBuildIdentity,
        ping: @escaping (CloudGatewayMacBuildIdentity) async throws -> CloudGatewayMacExtensionVersion?,
        registrationReadiness: @escaping () async -> CloudGatewayMacSetupState = { .required },
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
        self.extensionIdentity = extensionIdentity
        self.ping = ping
        self.registrationReadiness = registrationReadiness
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
    private var lastActivity: Date
    private var readinessTask: Task<Void, Never>?
    private var checkingInstallation = false
    private var extensionIsIdle = false
    private var setupState = CloudGatewayMacSetupState.required

    public init(identity: CloudGatewayMacBuildIdentity, effects: CloudGatewayMacControllerEffects,
                requests: CloudGatewayMacControllerRequests, extensionUpdates: CloudGatewayMacExtensionUpdateOrchestrator) {
        self.effects = effects
        self.requests = requests
        self.extensionUpdates = extensionUpdates
        update = .init(running: identity)
        lastActivity = effects.now()
    }

    public var canExit: Bool {
        guard activeRequests == 0, pending == nil, runningOperation == nil,
              !effects.hasPendingWork(), readinessTask == nil else { return false }
        if update.canExit(hasPendingWork: false, activeRequests: 0) { return true }
        // A retained result keeps the controller reachable for its ten-minute recovery window
        return !extensionUpdates.hasPendingAttempt && requests.latest == nil
            && effects.now().timeIntervalSince(lastActivity) >= 60
    }

    public func tick() async {
        guard !checkingInstallation else { return }
        checkingInstallation = true
        let installed = await effects.installedIdentity()
        checkingInstallation = false
        update.observe(installed)
        if update.isDraining {
            creation = nil
            preparationTask?.cancel()
        }
        expirePending()
        if effects.hasPendingWork() || runningOperation != nil { lastActivity = effects.now() }
        if canExit { return }
        if update.canAcceptMutations { refreshReadiness() }
    }

    public func handle(_ request: CloudGatewayMacControllerRequest) async -> CloudGatewayMacControllerReply {
        activeRequests += 1
        if !update.isDraining { lastActivity = effects.now() }
        defer {
            activeRequests -= 1
            if !update.isDraining { lastActivity = effects.now() }
        }
        expirePending()
        switch request.action {
        case .lifecycle:
            return .init(lifecycle: .init(running: update.running, installed: update.installed,
                                         state: update.isDraining ? .draining : update.installed == nil ? .invalidInstallation : .current))
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

    private func admit(_ request: CloudGatewayMacControllerRequest) -> CloudGatewayMacControllerReply {
        do {
            if let operation = try requests.lookup(request) {
                return operationReply(operation, request: request)
            }
            guard pending == nil, runningOperation == nil else { return .init(error: .busy) }
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
        guard let id = confirmation.contextId else { return .init(error: .invalidRequest) }
        guard let pending, pending.request.id == id else {
            return controlReply(for: confirmation, operation: requests.operation(id: id))
        }
        let request = pending.request
        let session = effects.session()
        guard request.action == .turnOff || (update.canAcceptMutations && confirmation.buildIdentity == update.running) else {
            self.pending = nil
            return controlReply(for: confirmation, operation: requests.finish(
                id: id, state: .failed, failure: .incompatibleVersion, outcome: .failed(.incompatibleVersion), session: session
            ))
        }
        // Account work runs only for the session that reserved it
        if request.action.hasAccountBoundOutcome, session != pending.session {
            self.pending = nil
            return controlReply(for: confirmation, operation: requests.finish(
                id: id, state: .failed, failure: .rejected, outcome: .failed(.signInRequired), session: session
            ))
        }
        if request.action == .createClient,
           creation?.id != request.contextId || creation.map({ $0.expires <= effects.now() }) != false {
            self.pending = nil
            return controlReply(for: confirmation, operation: requests.finish(id: id, state: .failed, failure: .preparationExpired))
        }
        self.pending = nil
        runningOperation = id
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
        lastActivity = effects.now()
    }

    private func expirePending() {
        guard let pending, pending.deadline <= effects.now() else { return }
        _ = requests.finish(id: pending.request.id, state: .unknown, outcome: .expired, session: effects.session())
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
        defer {
            if preparationId == id { preparationTask = nil; preparationId = nil }
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
        let outcome = request.buildIdentity == update.running ? operation.flatMap {
            requests.outcome(id: $0.id, session: effects.session())
        } : nil
        return .init(status: snapshot.status, operation: operation, outcome: outcome,
                     accepted: operation.map { $0.state != .failed && $0.state != .unknown }, operationId: operation?.id)
    }

    private func reply(operation: CloudGatewayMacControllerOperation? = nil,
                       refresh: CloudGatewayMacRefreshResult? = nil) -> CloudGatewayMacControllerReply {
        let operation = operation ?? requests.latest
        return .init(state: effects.snapshot(setupState, extensionIsIdle && !extensionUpdates.hasPendingAttempt && pending == nil && runningOperation == nil
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
            attempt = reserved
            setSetupState(.activating)
            guard try await !effects.hasAnyActiveTunnel(), update.canAcceptMutations,
                  try effects.extensionIdentity() == target else { throw CloudGatewayMacControllerFailure.busy }
            return .init(accepted: true, operationId: reserved.id, extensionTarget: target)
        } catch {
            if let attempt { try? extensionUpdates.handle(.failed, attemptId: attempt.id, installedTarget: attempt.target) }
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
            setSetupState(extensionUpdates.setupState ?? .checkingConnection)
            refreshReadiness()
            return .init(accepted: true)
        } catch {
            return .init(error: error as? CloudGatewayMacControllerFailure == .rejected ? .extensionAttemptChanged : .unavailable)
        }
    }

    private func refreshReadiness() {
        guard readinessTask == nil else { return }
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
            defer { readinessTask = nil }
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
}

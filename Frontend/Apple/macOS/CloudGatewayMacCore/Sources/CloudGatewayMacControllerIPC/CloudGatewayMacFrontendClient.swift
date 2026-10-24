import CloudGatewayMacCore
import CloudGatewayMacIPC
import Foundation

@MainActor
public final class CloudGatewayMacFrontendClient {
    public enum ConnectionState: Equatable, Sendable {
        case connected, reconnecting, draining, incompatible
    }

    public var onChange: (() -> Void)?
    public var onReplacement: ((CloudGatewayMacBuildIdentity) -> Void)?
    public private(set) var connectionState = ConnectionState.reconnecting
    public private(set) var snapshot: CloudGatewayMacControllerView?
    public private(set) var managedUpdate: CloudGatewayMacManagedUpdateStatus?
    public private(set) var isSnapshotFresh = false
    private(set) var isPollingPaused = false
    public private(set) var errorMessage: String?
    private let identity: CloudGatewayMacBuildIdentity
    private let transport: (CloudGatewayMacControllerRequest) async throws -> CloudGatewayMacControllerReply
    private let bootstrap: () async throws -> Void
    private let now: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var pollTask: Task<Void, Never>?
    private var pollingId: UUID?
    private var interactionTask: Task<Void, any Error>?
    private var lastActivity: Duration
    private var hasStarted = false
    private var hasPreparedStartup = false
    private var hasIdleSnapshot = false
    private var sequence: UInt64 = 0
    private var appliedSequence: UInt64 = 0
    private var generation: UInt64 = 0
    private var instanceId: UUID?
    private var safeStatus: CloudGatewayMacControllerStatus?
    private var isShuttingDown = false

    public init(identity: CloudGatewayMacBuildIdentity,
                transport: @escaping (CloudGatewayMacControllerRequest) async throws -> CloudGatewayMacControllerReply,
                bootstrap: @escaping () async throws -> Void,
                now: (@Sendable () -> Duration)? = nil,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.identity = identity
        self.transport = transport
        self.bootstrap = bootstrap
        let clock = ContinuousClock()
        let origin = clock.now
        let elapsed = now ?? { origin.duration(to: clock.now) }
        self.now = elapsed
        lastActivity = elapsed()
        self.sleep = sleep
    }

    public var isCurrentBuild: Bool { connectionState == .connected }

    public var presentation: CloudGatewayMacControllerView {
        if isSnapshotFresh, let snapshot { return snapshot }
        if hasIdleSnapshot, safeStatus == nil, let snapshot {
            return .init(groups: snapshot.groups.map { group in
                .init(regionId: group.regionId, title: group.title, rows: group.rows.map {
                    .init(identifier: $0.identifier, title: $0.title, status: nil, isEnabled: false)
                })
            }, statusTitle: "\(snapshot.statusTitle) (last observed)",
                canToggleVPN: snapshot.canTurnOff, canTurnOff: snapshot.canTurnOff,
                hasActiveTunnel: snapshot.hasActiveTunnel, canRefresh: snapshot.canRefresh, canSignOut: snapshot.canSignOut,
                accountId: snapshot.accountId, lastSelectedIdentifier: snapshot.lastSelectedIdentifier,
                browserState: snapshot.browserState, login: snapshot.login, setupState: snapshot.setupState,
                isRestoringSession: snapshot.isRestoringSession, isAuthSettling: snapshot.isAuthSettling,
                hasRetainedSession: snapshot.hasRetainedSession, errorMessage: snapshot.errorMessage)
        }
        let live = safeStatus?.observationAvailable == true
        let active = safeStatus?.hasActiveTunnel ?? snapshot?.hasActiveTunnel ?? false
        let canStop = live && safeStatus?.needsStop == true
        let title: String
        if live {
            switch safeStatus?.phase {
            case .connecting: title = "VPN connecting…"
            case .disconnecting: title = "VPN disconnecting…"
            case .connected: title = "VPN connected"
            default: title = "VPN off"
            }
        } else {
            title = snapshot.map {
                $0.statusTitle.hasSuffix("(last observed)") ? $0.statusTitle : "\($0.statusTitle) (last observed)"
            } ?? "Connecting to controller…"
        }
        return .init(statusTitle: title, canToggleVPN: canStop, canTurnOff: canStop, hasActiveTunnel: active,
                     setupState: snapshot?.setupState ?? .checkingConnection)
    }

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        startPolling()
    }

    private var shouldPoll: Bool {
        now() - lastActivity < .seconds(15 * 60)
    }

    private func pausePolling() {
        guard !isPollingPaused else { return }
        isPollingPaused = true
        hasIdleSnapshot = snapshot != nil
        isSnapshotFresh = false
        safeStatus = nil
        onChange?()
    }

    private func startPolling() {
        guard hasStarted, pollTask == nil, !isShuttingDown else { return }
        guard shouldPoll else { pausePolling(); return }
        let id = UUID()
        pollingId = id
        let prepareStartup = !hasPreparedStartup
        hasPreparedStartup = true
        pollTask = Task { [weak self] in
            defer {
                if let self, pollingId == id {
                    pollTask = nil
                    pollingId = nil
                }
            }
            if prepareStartup {
                guard let self else { return }
                do { try await prepareForInteraction() }
                catch {
                    guard !Task.isCancelled, !isShuttingDown else { return }
                    guard shouldPoll else { pausePolling(); return }
                    errorMessage = message(for: error)
                    onChange?()
                }
            }
            var delay = 1
            while !Task.isCancelled {
                guard let self, !isShuttingDown else { return }
                guard shouldPoll else { pausePolling(); return }
                do { try await poll(); delay = 1 }
                catch {
                    guard !Task.isCancelled, !isShuttingDown else { return }
                    guard shouldPoll else { pausePolling(); return }
                    delay = min(delay * 2, 10)
                }
                do { try await sleep(.seconds(delay)) }
                catch { return }
            }
        }
    }

    public func poll() async throws {
        if hasStarted, !shouldPoll { pausePolling(); return }
        let handshake = try await request(.lifecycle)
        if hasStarted, !shouldPoll { pausePolling(); return }
        guard let lifecycle = handshake.lifecycle else { throw CloudGatewayMacControllerFailure.invalidRequest }
        if lifecycle.state == .current, lifecycle.running == identity, lifecycle.installed == identity {
            _ = try await request(.snapshot)
        } else {
            _ = try await request(.status)
            if let installed = lifecycle.installed, installed != identity { onReplacement?(installed) }
        }
    }

    // Only real interactions resume idle polling or authorize another controller launch
    public func userRequest(_ action: CloudGatewayMacControllerRequest.Action, id: UUID = UUID(),
                            identifier: String? = nil, regionId: String? = nil, clientName: String? = nil,
                            contextId: UUID? = nil, loginOrigin: CloudGatewayMacLoginOrigin? = nil,
                            allowDisconnect: Bool? = nil) async throws -> CloudGatewayMacControllerReply {
        guard !isShuttingDown else { throw CancellationError() }
        try Task.checkCancellation()
        lastActivity = now()
        isPollingPaused = false
        startPolling()
        try await prepareForInteraction()
        try Task.checkCancellation()
        if action == .removeClient {
            guard let identifier, isSnapshotFresh, isCurrentBuild,
                  presentation.canReviewClient,
                  CloudGatewayMacControllerState.belongs(identifier, to: presentation.accountId),
                  presentation.groups.flatMap(\.rows).contains(where: {
                      $0.identifier == identifier && $0.removalPermission == .inactive
                  }) else { throw CloudGatewayMacControllerFailure.rejected }
        }
        if action == .menuWillOpen, !isCurrentBuild { return try await request(.status) }
        if action == .prepareExtensionUpdate, isCurrentBuild {
            _ = try await request(.recordActivity)
        }
        return try await request(action, id: id, identifier: identifier, regionId: regionId,
                                 clientName: clientName, contextId: contextId, loginOrigin: loginOrigin, allowDisconnect: allowDisconnect)
    }

    private func prepareForInteraction() async throws {
        if let interactionTask { return try await interactionTask.value }
        let task = Task { [self] in
            var launched = false
            let deadline = now() + .seconds(10)
            for attempt in 0..<40 {
                try Task.checkCancellation()
                guard !isShuttingDown else { throw CancellationError() }
                guard !hasStarted || shouldPoll else { throw CancellationError() }
                do {
                    guard let lifecycle = try await send(.lifecycle).lifecycle else {
                        throw CloudGatewayMacControllerFailure.invalidRequest
                    }
                    if let installed = lifecycle.installed, installed != identity { onReplacement?(installed) }
                    return
                } catch CloudGatewayMacControllerFailure.unavailable {
                    guard !hasStarted || shouldPoll else { throw CancellationError() }
                    guard attempt < 39, now() < deadline else { throw CloudGatewayMacControllerFailure.timeout }
                    if !launched {
                        launched = true
                        try await bootstrap()
                    }
                    try await sleep(.milliseconds(250))
                }
            }
        }
        interactionTask = task
        defer { interactionTask = nil }
        try await task.value
    }

    // Short-lived frontends start the controller once, then retry until the caller stops waiting
    public func handshake(retryDelay: Duration = .milliseconds(250)) async throws -> CloudGatewayMacControllerLifecycle {
        var isBootstrapped = false
        while true {
            do {
                guard let lifecycle = try await send(.lifecycle).lifecycle else {
                    throw CloudGatewayMacControllerFailure.invalidRequest
                }
                return lifecycle
            } catch CloudGatewayMacControllerFailure.unavailable {
                if !isBootstrapped {
                    try await bootstrap()
                    isBootstrapped = true
                }
                try await sleep(retryDelay)
            }
        }
    }

    public func shutdown() {
        isShuttingDown = true
        generation &+= 1
        pollTask?.cancel()
        pollTask = nil
        pollingId = nil
        interactionTask?.cancel()
        interactionTask = nil
        onChange = nil
        onReplacement = nil
        managedUpdate = nil
    }

    // Menu convenience: reserved mutations are confirmed at once, and failed or uncertain results throw
    public func request(_ action: CloudGatewayMacControllerRequest.Action, id: UUID = UUID(),
                        identifier: String? = nil, regionId: String? = nil, clientName: String? = nil,
                        contextId: UUID? = nil, loginOrigin: CloudGatewayMacLoginOrigin? = nil,
                        allowDisconnect: Bool? = nil) async throws -> CloudGatewayMacControllerReply {
        let reply = try await send(action, id: id, identifier: identifier, regionId: regionId,
                                   clientName: clientName, contextId: contextId, loginOrigin: loginOrigin, allowDisconnect: allowDisconnect)
        guard action.requiresConfirmation, reply.operation?.state == .accepted else { return reply }
        let confirmed = try await confirm(id)
        // Removal needs its typed terminal outcome, including immediate failures and cleanup warnings
        if action == .removeClient { return confirmed }
        if let operation = confirmed.operation, operation.state == .failed {
            throw operation.failure ?? CloudGatewayMacControllerFailure.rejected
        }
        if confirmed.operation?.state == .unknown { throw CloudGatewayMacControllerFailure.outcomeUnknown }
        return confirmed
    }

    // Mutations come back reserved. Nothing runs until the caller confirms the same ID
    public func send(_ action: CloudGatewayMacControllerRequest.Action, id: UUID = UUID(),
                     identifier: String? = nil, regionId: String? = nil, clientName: String? = nil,
                     contextId: UUID? = nil, loginOrigin: CloudGatewayMacLoginOrigin? = nil,
                     allowDisconnect: Bool? = nil) async throws -> CloudGatewayMacControllerReply {
        guard !isShuttingDown else { throw CancellationError() }
        let callback: Set<CloudGatewayMacControllerRequest.Action> = [
            .extensionUpdateStarted, .extensionUpdateApproval, .extensionUpdateRestart, .extensionUpdateFinished, .extensionUpdateFailed
        ]
        guard action.isCompatibleControl || isCurrentBuild || callback.contains(action) else {
            throw CloudGatewayMacControllerFailure.busy
        }
        try Task.checkCancellation()
        sequence &+= 1
        let currentSequence = sequence
        let currentGeneration = generation
        let request = CloudGatewayMacControllerRequest(action: action, id: id, identifier: identifier,
            regionId: regionId, clientName: clientName, contextId: contextId, loginOrigin: loginOrigin, allowDisconnect: allowDisconnect,
            appVersion: identity.version, appBuild: identity.build, buildIdentity: identity)
        let reply: CloudGatewayMacControllerReply
        do { reply = try await transport(request) }
        catch {
            if !(error is CancellationError), currentGeneration == generation, currentSequence >= appliedSequence {
                appliedSequence = currentSequence
                isSnapshotFresh = false
                managedUpdate = nil
                safeStatus = nil
                connectionState = error as? CloudGatewayMacControllerFailure == .incompatibleVersion ? .incompatible : .reconnecting
                errorMessage = message(for: error)
                onChange?()
            }
            throw error
        }
        try Task.checkCancellation()
        guard !isShuttingDown else { throw CancellationError() }
        guard currentGeneration == generation else { throw Self.fencedFailure(for: action) }
        if let failure = reply.error { throw failure }
        if action == .lifecycle, currentSequence >= appliedSequence, let lifecycle = reply.lifecycle {
            appliedSequence = currentSequence
            if instanceId != nil, instanceId != reply.instanceId {
                generation &+= 1
                isSnapshotFresh = false
                managedUpdate = nil
                safeStatus = nil
            }
            instanceId = reply.instanceId
            connectionState = lifecycle.state == .current && lifecycle.running == identity && lifecycle.installed == identity
                ? .connected : .draining
            if connectionState != .connected { isSnapshotFresh = false; managedUpdate = nil }
            errorMessage = connectionState == .draining ? "CloudGateway is updating. Finishing current operations…" : nil
            onChange?()
        } else if currentSequence >= appliedSequence {
            guard reply.instanceId == instanceId else {
                generation &+= 1
                isSnapshotFresh = false
                managedUpdate = nil
                safeStatus = nil
                connectionState = .reconnecting
                errorMessage = "The controller restarted. Reconnecting…"
                onChange?()
                throw Self.fencedFailure(for: action)
            }
            appliedSequence = currentSequence
            managedUpdate = isCurrentBuild ? reply.update : nil
            if let state = reply.state, isCurrentBuild {
                snapshot = .init(state: state)
                isSnapshotFresh = !hasStarted || shouldPoll
                safeStatus = state.status
                hasIdleSnapshot = !isSnapshotFresh
                if !isSnapshotFresh { safeStatus = nil; isPollingPaused = true }
                errorMessage = nil
                onChange?()
            } else if let status = reply.status {
                safeStatus = hasStarted && !shouldPoll ? nil : status
                if action == .status { isSnapshotFresh = false }
                onChange?()
            }
        }
        return reply
    }

    // A lost confirmation may have started the work, so it is reported as uncertain and never resent
    public func confirm(_ id: UUID) async throws -> CloudGatewayMacControllerReply {
        do { return try await send(.confirmOperation, contextId: id) }
        catch {
            if error is CancellationError, Task.isCancelled { throw error }
            throw CloudGatewayMacControllerFailure.outcomeUnknown
        }
    }

    // Stopping early only detaches this caller. The controller keeps confirmed work running.
    // Cancellation means the caller stopped waiting, while timeout means its own deadline passed
    public func awaitOutcome(of id: UUID, timeout: Duration,
                             interval: Duration = .milliseconds(500)) async throws -> CloudGatewayMacControllerReply {
        let deadline = now() + timeout
        while true {
            let reply = try await lookup(id, until: deadline)
            if let state = reply.operation?.state, state != .accepted, state != .running { return reply }
            let remaining = deadline - now()
            guard remaining > .zero else { throw CloudGatewayMacControllerFailure.timeout }
            try await sleep(min(interval, remaining))
        }
    }

    // The transport's own reply timer must not outlast a shorter caller deadline
    private func lookup(_ id: UUID, until deadline: Duration) async throws -> CloudGatewayMacControllerReply {
        let race = ControllerReplyRace()
        let request = Task {
            do { race.finish(.success(try await send(.operation, contextId: id))) }
            catch { race.finish(.failure(error is CancellationError ? CloudGatewayMacControllerFailure.unavailable : error)) }
        }
        let timer = Task {
            guard !race.isFinished else { return }
            do { try await sleep(max(deadline - now(), .zero)) } catch { return }
            race.finish(.failure(CloudGatewayMacControllerFailure.timeout))
        }
        defer {
            request.cancel()
            timer.cancel()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { race.start($0) }
        } onCancel: {
            Task { @MainActor in race.finish(.failure(CancellationError())) }
        }
    }

    // A reply from a replaced controller cannot show whether confirmed work ran
    private static func fencedFailure(for action: CloudGatewayMacControllerRequest.Action) -> CloudGatewayMacControllerFailure {
        action == .confirmOperation || action == .operation ? .outcomeUnknown : .unavailable
    }

    public func message(for error: Error) -> String {
        if let launch = error as? CloudGatewayMacControllerLaunchError,
           case .bootstrapFailed(let category, let status) = launch {
            let exit = status.map { " (exit \($0))" } ?? ""
            return "Controller startup failed: \(category.rawValue)\(exit). Reopen CloudGateway"
        }
        if error as? CloudGatewayMacControllerLaunchError == .installationRequired {
            return "Install CloudGateway in /Applications to start the controller"
        }
        switch error as? CloudGatewayMacControllerFailure {
        case .incompatibleVersion: return "CloudGateway is updating. Waiting for the installed controller"
        case .invalidRequest: return "The controller returned an invalid response. Reopen CloudGateway"
        case .outcomeUnknown: return "The previous operation could not be confirmed. Check VPN status before trying again"
        case .busy: return "Another operation is in progress. Wait for it to finish and try again"
        case .rejected: return "Account or client list changed. Refresh and try again"
        case .commandFailed: return "The command failed. Refresh VPN status before trying again"
        case .authCleanupFailed: return "Sign Out did not finish. Retry sign-in cleanup"
        case .extensionAttemptChanged: return "VPN extension update changed. Refresh status before trying again"
        case .preparationExpired: return "The Add Client request expired. Open Add Client again"
        case .timeout: return "Controller request timed out. Refresh status before trying the action again"
        default: return "Unable to reach the controller. Reconnecting…"
        }
    }
}

@MainActor
private final class ControllerReplyRace {
    private var continuation: CheckedContinuation<CloudGatewayMacControllerReply, any Error>?
    private var result: Result<CloudGatewayMacControllerReply, any Error>?

    var isFinished: Bool { result != nil }

    func start(_ continuation: CheckedContinuation<CloudGatewayMacControllerReply, any Error>) {
        if let result { continuation.resume(with: result) }
        else { self.continuation = continuation }
    }

    func finish(_ result: Result<CloudGatewayMacControllerReply, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

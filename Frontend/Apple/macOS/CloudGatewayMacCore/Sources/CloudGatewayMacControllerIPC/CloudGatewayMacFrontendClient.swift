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
    public private(set) var isSnapshotFresh = false
    public private(set) var errorMessage: String?
    private let identity: CloudGatewayMacBuildIdentity
    private let transport: (CloudGatewayMacControllerRequest) async throws -> CloudGatewayMacControllerReply
    private let bootstrap: () async throws -> Void
    private let now: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var pollTask: Task<Void, Never>?
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
        self.now = now ?? { origin.duration(to: clock.now) }
        self.sleep = sleep
    }

    public var isCurrentBuild: Bool { connectionState == .connected }

    public var presentation: CloudGatewayMacControllerView {
        if isSnapshotFresh, let snapshot { return snapshot }
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
        guard pollTask == nil, !isShuttingDown else { return }
        pollTask = Task { [weak self] in
            var delay = 1
            while !Task.isCancelled {
                guard let self, !isShuttingDown else { return }
                do { try await poll(); delay = 1 }
                catch {
                    guard !Task.isCancelled, !isShuttingDown else { return }
                    if error as? CloudGatewayMacControllerFailure != .incompatibleVersion {
                        do { try await bootstrap() }
                        catch { errorMessage = message(for: error); onChange?() }
                    }
                    delay = min(delay * 2, 10)
                }
                do { try await sleep(.seconds(delay)) }
                catch { return }
            }
        }
    }

    public func poll() async throws {
        let handshake = try await request(.lifecycle)
        guard let lifecycle = handshake.lifecycle else { throw CloudGatewayMacControllerFailure.invalidRequest }
        if lifecycle.state == .current, lifecycle.running == identity, lifecycle.installed == identity {
            _ = try await request(.snapshot)
        } else {
            _ = try await request(.status)
            if let installed = lifecycle.installed, installed != identity { onReplacement?(installed) }
        }
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
        onChange = nil
        onReplacement = nil
    }

    // Menu convenience: reserved mutations are confirmed at once, and failed or uncertain results throw
    public func request(_ action: CloudGatewayMacControllerRequest.Action, id: UUID = UUID(),
                        identifier: String? = nil, regionId: String? = nil, clientName: String? = nil,
                        contextId: UUID? = nil, loginOrigin: CloudGatewayMacLoginOrigin? = nil) async throws -> CloudGatewayMacControllerReply {
        let reply = try await send(action, id: id, identifier: identifier, regionId: regionId,
                                   clientName: clientName, contextId: contextId, loginOrigin: loginOrigin)
        guard action.requiresConfirmation, reply.operation?.state == .accepted else { return reply }
        let confirmed = try await confirm(id)
        if let operation = confirmed.operation, operation.state == .failed {
            throw operation.failure ?? CloudGatewayMacControllerFailure.rejected
        }
        if confirmed.operation?.state == .unknown { throw CloudGatewayMacControllerFailure.outcomeUnknown }
        return confirmed
    }

    // Mutations come back reserved. Nothing runs until the caller confirms the same ID
    public func send(_ action: CloudGatewayMacControllerRequest.Action, id: UUID = UUID(),
                     identifier: String? = nil, regionId: String? = nil, clientName: String? = nil,
                     contextId: UUID? = nil, loginOrigin: CloudGatewayMacLoginOrigin? = nil) async throws -> CloudGatewayMacControllerReply {
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
            regionId: regionId, clientName: clientName, contextId: contextId, loginOrigin: loginOrigin,
            appVersion: identity.version, appBuild: identity.build, buildIdentity: identity)
        let reply: CloudGatewayMacControllerReply
        do { reply = try await transport(request) }
        catch {
            if !(error is CancellationError), currentGeneration == generation, currentSequence >= appliedSequence {
                appliedSequence = currentSequence
                isSnapshotFresh = false
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
                safeStatus = nil
            }
            instanceId = reply.instanceId
            connectionState = lifecycle.state == .current && lifecycle.running == identity && lifecycle.installed == identity
                ? .connected : .draining
            if connectionState != .connected { isSnapshotFresh = false }
            errorMessage = connectionState == .draining ? "CloudGateway is updating. Finishing current operations…" : nil
            onChange?()
        } else if currentSequence >= appliedSequence {
            guard reply.instanceId == instanceId else {
                generation &+= 1
                isSnapshotFresh = false
                safeStatus = nil
                connectionState = .reconnecting
                errorMessage = "The controller restarted. Reconnecting…"
                onChange?()
                throw Self.fencedFailure(for: action)
            }
            appliedSequence = currentSequence
            if let state = reply.state, isCurrentBuild {
                snapshot = .init(state: state)
                isSnapshotFresh = true
                safeStatus = state.status
                errorMessage = nil
                onChange?()
            } else if let status = reply.status {
                safeStatus = status
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

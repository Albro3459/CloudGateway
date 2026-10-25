import CloudGatewayMacControllerIPC
import Foundation

struct CloudGatewayMacCLIClock: Sendable {
    let now: @Sendable () -> Duration
    let sleep: @Sendable (Duration) async throws -> Void
    // Fires when the caller deadline passes, cancelling any controller call still in flight
    let timer: @Sendable (Duration) async throws -> Void

    static var continuous: Self {
        let clock = ContinuousClock()
        let origin = clock.now
        return .init(now: { origin.duration(to: clock.now) },
                     sleep: { try await Task.sleep(for: $0) }, timer: { try await Task.sleep(for: $0) })
    }
}

// One invocation's view of the controller. Every call shares the caller deadline
@MainActor
final class CloudGatewayMacCLISession {
    static let pollInterval = Duration.milliseconds(500)
    static let observationWait = Duration.seconds(5)

    let client: CloudGatewayMacFrontendClient
    let clock: CloudGatewayMacCLIClock
    let deadline: Duration
    private var didReportActivity = false

    init(client: CloudGatewayMacFrontendClient, clock: CloudGatewayMacCLIClock, timeout: Duration, startedAt: Duration? = nil) {
        self.client = client
        self.clock = clock
        deadline = (startedAt ?? clock.now()) + timeout
    }

    func authStatus() async throws -> CloudGatewayMacCLIData {
        try await requireCurrentBuild()
        let (reply, _) = try await poll(.snapshot, until: deadline) { try Self.state(of: $0).isPendingRestoration }
        return .auth(.init(try Self.state(of: reply)))
    }

    func inventory(regionId: String?, isLong: Bool = false) async throws -> CloudGatewayMacCLIData {
        try await requireCurrentBuild()
        let (reply, isSettled) = try await poll(.snapshot, until: deadline) {
            let state = try Self.state(of: $0)
            return state.isPendingRestoration || state.isAwaitingVerification || state.inventory == .refreshing
        }
        let state = try Self.state(of: reply)
        guard isSettled else {
            throw CloudGatewayMacCLIError(.timeout, message: state.isPendingRestoration
                ? "CloudGateway is still restoring this session" : "CloudGateway is still loading inventory")
        }
        guard let accountId = state.accountId else {
            if state.access == .denied { throw CloudGatewayMacCLIError(.accessDenied) }
            if state.hasRetainedSession, state.access == .unreachable {
                throw CloudGatewayMacCLIError(.networkUnavailable, message: "Unable to reach CloudGateway to restore this account")
            }
            throw CloudGatewayMacCLIError(.signInRequired)
        }
        guard state.inventory != .unavailable else {
            throw CloudGatewayMacCLIError(.networkUnavailable, message: "Inventory is unavailable for this account")
        }
        let regionId = try regionId.map {
            try CloudGatewayMacCLIInventoryOrder.region($0, in: CloudGatewayMacCLIInventoryOrder.regions(state, accountId: accountId))
        }
        return .inventory(.init(state, accountId: accountId, regionId: regionId, isLong: isLong))
    }

    // Other builds can still read the compatible status, without account details
    func status() async throws -> CloudGatewayMacCLIData {
        _ = try await connect()
        let limit = min(deadline, clock.now() + Self.observationWait)
        if client.isCurrentBuild {
            let (reply, _) = try await poll(.snapshot, until: limit) { try !Self.state(of: $0).observationAvailable }
            return .status(.init(tunnel: .init(try Self.state(of: reply)), operation: Self.operation(of: reply),
                                 update: reply.update.map(CloudGatewayMacCLIUpdate.init)))
        }
        let (reply, _) = try await poll(.status, until: limit) { try !Self.status(of: $0).observationAvailable }
        return .status(.init(tunnel: .init(try Self.status(of: reply)), operation: Self.operation(of: reply)))
    }

    // A single lookup. Unknown IDs still report the current observed state
    func operation(_ id: UUID) async throws -> CloudGatewayMacCLIData {
        _ = try await connect()
        let reply = try await call { [client] in try await client.send(.operation, contextId: id) }
        guard reply.operation?.id == id, let operation = Self.operation(of: reply) else {
            throw CloudGatewayMacCLIError(.invalidResponse)
        }
        let tunnel: CloudGatewayMacCLIStatus.Tunnel = if client.isCurrentBuild, let state = reply.state { .init(state) }
            else { .init(try Self.status(of: reply)) }
        let update = client.isCurrentBuild ? reply.update : nil
        if let update, update.id != id { throw CloudGatewayMacCLIError(.invalidResponse) }
        let data = CloudGatewayMacCLIData.status(.init(tunnel: tunnel, operation: operation,
                                                     update: update.map(CloudGatewayMacCLIUpdate.init)))
        guard var failure = Self.updateFailure(update) ?? operation.failure else { return data }
        if update != nil { failure = Self.updateObservationFailure(failure, id: id) }
        failure.data = data
        throw failure
    }

    private func connect() async throws -> CloudGatewayMacControllerLifecycle {
        let lifecycle = try await call { [client] in try await client.handshake() }
        if client.isCurrentBuild, !didReportActivity {
            _ = try await call { [client] in try await client.send(.userActivity) }
            didReportActivity = true
        }
        return lifecycle
    }

    func requireCurrentBuild() async throws {
        let lifecycle = try await connect()
        guard client.isCurrentBuild else {
            throw CloudGatewayMacCLIError(lifecycle.state == .invalidInstallation ? .installationRequired : .incompatibleVersion)
        }
    }

    func poll(
        _ action: CloudGatewayMacControllerRequest.Action, until limit: Duration,
        while isPending: (CloudGatewayMacControllerReply) throws -> Bool
    ) async throws -> (CloudGatewayMacControllerReply, isSettled: Bool) {
        while true {
            let reply = try await call { [client] in try await client.send(action) }
            guard try isPending(reply) else { return (reply, true) }
            guard clock.now() + Self.pollInterval < limit else { return (reply, false) }
            try await clock.sleep(Self.pollInterval)
        }
    }

    func call<Value: Sendable>(
        _ work: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        try await Self.call(clock: clock, deadline: deadline, work)
    }

    static func call<Value: Sendable>(clock: CloudGatewayMacCLIClock, deadline: Duration,
                                      _ work: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        let remaining = deadline - clock.now()
        guard remaining > .zero else { throw CloudGatewayMacControllerFailure.timeout }
        try Task.checkCancellation()
        let race = CloudGatewayMacCLICallRace<Value>()
        let request = Task {
            do { race.finish(.success(try await work())) }
            catch { race.finish(.failure(error)) }
        }
        let timer = Task { [clock] in
            do { try await clock.timer(remaining) }
            catch { return }
            race.finish(.failure(CloudGatewayMacControllerFailure.timeout))
        }
        defer { request.cancel(); timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { race.start($0) }
        } onCancel: {
            Task { @MainActor in race.finish(.failure(CancellationError())) }
        }
    }

    static func state(of reply: CloudGatewayMacControllerReply) throws -> CloudGatewayMacControllerState {
        guard let state = reply.state else { throw CloudGatewayMacCLIError(.invalidResponse) }
        return state
    }

    static func status(of reply: CloudGatewayMacControllerReply) throws -> CloudGatewayMacControllerStatus {
        guard let status = reply.status else { throw CloudGatewayMacCLIError(.invalidResponse) }
        return status
    }

    static func operation(of reply: CloudGatewayMacControllerReply) -> CloudGatewayMacCLIOperation? {
        reply.operation.map { CloudGatewayMacCLIOperation($0, outcome: reply.outcome) }
    }
}

@MainActor
private final class CloudGatewayMacCLICallRace<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?

    func start(_ continuation: CheckedContinuation<Value, any Error>) {
        if let result { continuation.resume(with: result) }
        else { self.continuation = continuation }
    }

    func finish(_ result: Result<Value, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

extension CloudGatewayMacControllerState {
    // Restoration can briefly clear its task before the authorized account is published
    var isAwaitingVerification: Bool {
        accountId == nil && hasRetainedSession && access == .unverified
    }
}

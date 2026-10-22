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

    private let client: CloudGatewayMacFrontendClient
    private let clock: CloudGatewayMacCLIClock
    private let deadline: Duration

    init(client: CloudGatewayMacFrontendClient, clock: CloudGatewayMacCLIClock, timeout: Duration) {
        self.client = client
        self.clock = clock
        deadline = clock.now() + timeout
    }

    func authStatus() async throws -> CloudGatewayMacCLIData {
        try await requireCurrentBuild()
        let (reply, _) = try await poll(.snapshot, until: deadline) { try Self.state(of: $0).isPendingRestoration }
        return .auth(.init(try Self.state(of: reply)))
    }

    func inventory(regionId: String?) async throws -> CloudGatewayMacCLIData {
        try await requireCurrentBuild()
        let (reply, isSettled) = try await poll(.snapshot, until: deadline) {
            let state = try Self.state(of: $0)
            return state.isPendingRestoration || state.inventory == .refreshing
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
        return .inventory(.init(state, accountId: accountId, regionId: regionId))
    }

    // Other builds can still read the compatible status, without account details
    func status() async throws -> CloudGatewayMacCLIData {
        _ = try await connect()
        let limit = min(deadline, clock.now() + Self.observationWait)
        if client.isCurrentBuild {
            let (reply, _) = try await poll(.snapshot, until: limit) { try !Self.state(of: $0).observationAvailable }
            return .status(.init(tunnel: .init(try Self.state(of: reply)), operation: Self.operation(of: reply)))
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
        let data = CloudGatewayMacCLIData.status(.init(tunnel: .init(try Self.status(of: reply)), operation: operation))
        guard var failure = operation.failure else { return data }
        failure.data = data
        throw failure
    }

    private func connect() async throws -> CloudGatewayMacControllerLifecycle {
        try await call { [client] in try await client.handshake() }
    }

    private func requireCurrentBuild() async throws {
        let lifecycle = try await connect()
        guard client.isCurrentBuild else {
            throw CloudGatewayMacCLIError(lifecycle.state == .invalidInstallation ? .installationRequired : .incompatibleVersion)
        }
    }

    private func poll(
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

    private func call<Value: Sendable>(
        _ work: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        let remaining = deadline - clock.now()
        guard remaining > .zero else { throw CloudGatewayMacControllerFailure.timeout }
        let timer = clock.timer
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await timer(remaining)
                throw CloudGatewayMacControllerFailure.timeout
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CloudGatewayMacControllerFailure.timeout }
            return value
        }
    }

    private static func state(of reply: CloudGatewayMacControllerReply) throws -> CloudGatewayMacControllerState {
        guard let state = reply.state else { throw CloudGatewayMacCLIError(.invalidResponse) }
        return state
    }

    private static func status(of reply: CloudGatewayMacControllerReply) throws -> CloudGatewayMacControllerStatus {
        guard let status = reply.status else { throw CloudGatewayMacCLIError(.invalidResponse) }
        return status
    }

    private static func operation(of reply: CloudGatewayMacControllerReply) -> CloudGatewayMacCLIOperation? {
        reply.operation.map { CloudGatewayMacCLIOperation($0, outcome: reply.outcome) }
    }
}

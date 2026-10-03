import Foundation

public enum CloudGatewayMacTunnelLifecycleError: Error, Equatable, Sendable {
    case busy
    case cancelled
    case stopUnconfirmed
}

public final class CloudGatewayMacTunnelLifecycle: @unchecked Sendable {
    public typealias StartCompletion = @Sendable (Error?) -> Void
    public typealias StopCompletion = @Sendable () -> Void

    public final class StartAttempt: Sendable {
        private let lifecycle: CloudGatewayMacTunnelLifecycle
        private let id: UUID

        fileprivate init(lifecycle: CloudGatewayMacTunnelLifecycle, id: UUID) {
            self.lifecycle = lifecycle
            self.id = id
        }

        public func submitAdapterStart(
            _ operation: @escaping @Sendable (@escaping StartCompletion) -> Void
        ) {
            lifecycle.submitAdapterStart(id: id, operation: operation)
        }

        public func fail(_ error: Error) {
            lifecycle.queue.async { [lifecycle, id] in
                lifecycle.finishStart(id: id, error: error)
            }
        }
    }

    private final class Session {
        let id = UUID()
        var startCompletion: StartCompletion?
        var stopping = false
        var stopCompletions: [StopCompletion] = []
        var stopDeadlineExpired = false
        var adapterSubmitted = false

        init(completion: @escaping StartCompletion) {
            startCompletion = completion
        }
    }

    private let queue: DispatchQueue
    private let scheduleStopDeadline: @Sendable (@escaping StopCompletion) -> Void
    private var session: Session?

    public init(
        queue: DispatchQueue = DispatchQueue(label: "com.gocloudlaunch.gateway.macos.tunnel.lifecycle"),
        stopTimeout: TimeInterval = 5,
        scheduleStopDeadline: (@Sendable (@escaping StopCompletion) -> Void)? = nil
    ) {
        self.queue = queue
        self.scheduleStopDeadline = scheduleStopDeadline ?? { completion in
            queue.asyncAfter(deadline: .now() + stopTimeout, execute: completion)
        }
    }

    public func start(
        operation: @escaping @Sendable (StartAttempt) -> Void,
        completion: @escaping StartCompletion
    ) {
        queue.async { [self] in
            guard session == nil else {
                completion(session?.stopDeadlineExpired == true
                    ? CloudGatewayMacTunnelLifecycleError.stopUnconfirmed
                    : CloudGatewayMacTunnelLifecycleError.busy)
                return
            }
            let next = Session(completion: completion)
            session = next
            operation(StartAttempt(lifecycle: self, id: next.id))
        }
    }

    public func stop(
        operation: @escaping @Sendable (@escaping StopCompletion) -> Void,
        completion: @escaping StopCompletion
    ) {
        queue.async { [self] in
            guard let session else {
                completion()
                return
            }
            session.stopCompletions.append(completion)
            guard !session.stopping else { return }
            session.stopping = true
            let startCompletion = session.startCompletion
            session.startCompletion = nil
            startCompletion?(CloudGatewayMacTunnelLifecycleError.cancelled)
            let id = session.id
            guard session.adapterSubmitted else {
                self.session = nil
                session.stopCompletions.forEach { $0() }
                return
            }
            scheduleStopDeadline { [weak self] in
                self?.queue.async { [weak self] in
                    self?.finishStop(id: id, confirmed: false)
                }
            }
            operation { [weak self] in
                self?.queue.async { [weak self] in
                    self?.finishStop(id: id, confirmed: true)
                }
            }
        }
    }

    private func submitAdapterStart(
        id: UUID,
        operation: @escaping @Sendable (@escaping StartCompletion) -> Void
    ) {
        queue.async { [self] in
            guard let session, session.id == id, !session.stopping,
                  !session.adapterSubmitted, session.startCompletion != nil else { return }
            session.adapterSubmitted = true
            operation { [weak self] error in
                self?.queue.async { [weak self] in
                    self?.finishStart(id: id, error: error)
                }
            }
        }
    }

    private func finishStart(id: UUID, error: Error?) {
        guard let session, session.id == id, !session.stopping,
              let completion = session.startCompletion else { return }
        session.startCompletion = nil
        if error != nil {
            self.session = nil
        }
        completion(error)
    }

    private func finishStop(id: UUID, confirmed: Bool) {
        guard let session, session.id == id, session.stopping else { return }
        guard confirmed else {
            session.stopDeadlineExpired = true
            return
        }
        let completions = session.stopCompletions
        session.stopCompletions = []
        self.session = nil
        completions.forEach { $0() }
    }
}

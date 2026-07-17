import Foundation

public enum CloudGatewayTunnelBackendRestartCapability: Equatable, Sendable {
    case supported
    case unsupported
}

public struct CloudGatewayTunnelHealthSession: Hashable, Sendable {
    fileprivate let generation: UInt64

    fileprivate init(generation: UInt64) {
        self.generation = generation
    }
}

public protocol CloudGatewayTunnelHealthRuntimeAdapter: Sendable {
    var backendRestartCapability: CloudGatewayTunnelBackendRestartCapability { get }

    func readRuntime(
        completion: @escaping @Sendable (CloudGatewayTunnelRuntimeStats?) async -> Void
    )

    func refreshBinding(
        completion: @escaping @Sendable (CloudGatewayTunnelRecoveryResult) async -> Void
    )

    func restartBackend(
        completion: @escaping @Sendable (CloudGatewayTunnelRecoveryResult) async -> Void
    )
}

public protocol CloudGatewayTunnelHealthPersistenceAdapter: Sendable {
    func write(
        _ snapshot: CloudGatewayTunnelHealthSnapshot,
        completion: @escaping @Sendable (CloudGatewayTunnelEffectResult) async -> Void
    )

    func clear(
        completion: @escaping @Sendable (CloudGatewayTunnelEffectResult) async -> Void
    )
}

public protocol CloudGatewayTunnelHealthNotificationAdapter: Sendable {
    func resumeRegistrations()
    func suspendRegistrations()
    func invalidateRegistrations()

    func register(
        completion: @escaping @Sendable (CloudGatewayTunnelNotificationResult) async -> Void
    )

    func reconcile(
        completion: @escaping @Sendable (CloudGatewayTunnelNotificationResult) async -> Void
    )

    func withdraw()
}

public extension CloudGatewayTunnelHealthNotificationAdapter {
    func resumeRegistrations() {}
    func suspendRegistrations() { invalidateRegistrations() }
}

public protocol CloudGatewayTunnelHealthWakeCancellation: Sendable {
    func cancel()
}

public protocol CloudGatewayTunnelHealthScheduling: Sendable {
    func now() -> CloudGatewayTunnelHealthMoment

    func schedule(
        at deadline: Duration,
        action: @escaping @Sendable () async -> Void
    ) -> any CloudGatewayTunnelHealthWakeCancellation
}

public struct CloudGatewayTunnelHealthStoreAdapter: CloudGatewayTunnelHealthPersistenceAdapter {
    private let lane: CloudGatewayTunnelHealthStoreLane

    public init(store: CloudGatewayTunnelHealthStore) {
        lane = CloudGatewayTunnelHealthStoreLane(
            write: { try store.write($0) },
            clear: { try store.clear() }
        )
    }

    init(
        write: @escaping @Sendable (CloudGatewayTunnelHealthSnapshot) throws -> Void,
        clear: @escaping @Sendable () throws -> Void,
        executor: any CloudGatewayTunnelHealthStoreExecuting =
            CloudGatewayTunnelHealthStoreSerialExecutor()
    ) {
        lane = CloudGatewayTunnelHealthStoreLane(
            write: write,
            clear: clear,
            executor: executor
        )
    }

    public func write(
        _ snapshot: CloudGatewayTunnelHealthSnapshot,
        completion: @escaping @Sendable (CloudGatewayTunnelEffectResult) async -> Void
    ) {
        lane.write(snapshot, completion: completion)
    }

    public func clear(
        completion: @escaping @Sendable (CloudGatewayTunnelEffectResult) async -> Void
    ) {
        lane.clear(completion: completion)
    }
}

protocol CloudGatewayTunnelHealthStoreExecuting: Sendable {
    func enqueue(_ action: @escaping @Sendable () -> Void)
}

private final class CloudGatewayTunnelHealthStoreSerialExecutor:
    CloudGatewayTunnelHealthStoreExecuting,
    @unchecked Sendable
{
    private let queue = DispatchQueue(
        label: "com.gocloudlaunch.gateway.tunnel.health.persistence"
    )

    func enqueue(_ action: @escaping @Sendable () -> Void) {
        queue.async(execute: action)
    }
}

private final class CloudGatewayTunnelHealthStoreLane: @unchecked Sendable {
    private let executor: any CloudGatewayTunnelHealthStoreExecuting
    private let writeOperation: @Sendable (CloudGatewayTunnelHealthSnapshot) throws -> Void
    private let clearOperation: @Sendable () throws -> Void
    private let callbackLock = NSLock()
    private var callbackTail: Task<Void, Never>?

    init(
        write: @escaping @Sendable (CloudGatewayTunnelHealthSnapshot) throws -> Void,
        clear: @escaping @Sendable () throws -> Void,
        executor: any CloudGatewayTunnelHealthStoreExecuting =
            CloudGatewayTunnelHealthStoreSerialExecutor()
    ) {
        writeOperation = write
        clearOperation = clear
        self.executor = executor
    }

    func write(
        _ snapshot: CloudGatewayTunnelHealthSnapshot,
        completion: @escaping @Sendable (CloudGatewayTunnelEffectResult) async -> Void
    ) {
        executor.enqueue { [self] in
            let result: CloudGatewayTunnelEffectResult
            do {
                try writeOperation(snapshot)
                result = .success
            } catch {
                result = .failure
            }
            deliver(result, completion: completion)
        }
    }

    func clear(
        completion: @escaping @Sendable (CloudGatewayTunnelEffectResult) async -> Void
    ) {
        executor.enqueue { [self] in
            let result: CloudGatewayTunnelEffectResult
            do {
                try clearOperation()
                result = .success
            } catch {
                result = .failure
            }
            deliver(result, completion: completion)
        }
    }

    private func deliver(
        _ result: CloudGatewayTunnelEffectResult,
        completion: @escaping @Sendable (CloudGatewayTunnelEffectResult) async -> Void
    ) {
        callbackLock.lock()
        let previous = callbackTail
        callbackTail = Task {
            if let previous {
                await previous.value
            }
            await completion(result)
        }
        callbackLock.unlock()
    }
}

public struct CloudGatewayTunnelHealthTaskScheduler: CloudGatewayTunnelHealthScheduling {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        origin = clock.now
    }

    public func now() -> CloudGatewayTunnelHealthMoment {
        CloudGatewayTunnelHealthMoment(
            monotonic: origin.duration(to: clock.now),
            wall: Date()
        )
    }

    public func schedule(
        at deadline: Duration,
        action: @escaping @Sendable () async -> Void
    ) -> any CloudGatewayTunnelHealthWakeCancellation {
        let delay = max(.zero, deadline - now().monotonic)
        let clock = clock
        let task = Task {
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await action()
        }
        return CloudGatewayTunnelHealthTaskCancellation(task: task)
    }
}

private final class CloudGatewayTunnelHealthTaskCancellation:
    CloudGatewayTunnelHealthWakeCancellation,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        lock.lock()
        let task = task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }

    deinit {
        cancel()
    }
}

public final class CloudGatewayTunnelHealthStopToken: @unchecked Sendable {
    let generation: UInt64
    private let effectArbiter: CloudGatewayTunnelHealthEffectSubmissionArbiter
    private let lock = NSLock()
    private var cleanup: (@Sendable () -> Void)?

    init(
        generation: UInt64,
        effectArbiter: CloudGatewayTunnelHealthEffectSubmissionArbiter,
        cleanup: @escaping @Sendable () -> Void
    ) {
        self.generation = generation
        self.effectArbiter = effectArbiter
        self.cleanup = cleanup
    }

    convenience init(
        generation: UInt64,
        effectGate: CloudGatewayTunnelHealthEffectGate,
        cleanup: @escaping @Sendable () -> Void
    ) {
        self.init(
            generation: generation,
            effectArbiter: effectGate,
            cleanup: cleanup
        )
    }

    public func bestEffortDeadlineCleanup() {
        lock.lock()
        let cleanup = cleanup
        self.cleanup = nil
        lock.unlock()
        guard let cleanup else { return }
        effectArbiter.addPostDrainRepair(
            generation: generation,
            cleanup
        )
        cleanup()
    }

    public func enqueueAfterSubmittedEffects(
        _ action: @escaping @Sendable () -> Void
    ) {
        effectArbiter.enqueueNormalStop(
            generation: generation,
            action
        )
    }

    public func cancelQueuedEffectsAndEnqueue(
        _ action: @escaping @Sendable () -> Void
    ) {
        effectArbiter.cancelQueuedAndEnqueueDeadlineStop(
            generation: generation,
            action
        )
    }

    public func disarmDeadlineCleanup() {
        lock.lock()
        cleanup = nil
        lock.unlock()
    }
}

public actor CloudGatewayTunnelHealthMonitor {
    private struct ScheduledWake: Sendable {
        let token: UInt64
        let deadline: Duration
        let cancellation: any CloudGatewayTunnelHealthWakeCancellation
    }

    private let runtime: any CloudGatewayTunnelHealthRuntimeAdapter
    private let scheduler: any CloudGatewayTunnelHealthScheduling
    private let artifactDriver: CloudGatewayTunnelHealthArtifactDriver
    private nonisolated let effectArbiter: CloudGatewayTunnelHealthEffectSubmissionArbiter
    private nonisolated let notifications: any CloudGatewayTunnelHealthNotificationAdapter
    private nonisolated let artifactIntent: CloudGatewayTunnelHealthArtifactIntent
    private nonisolated let deadlineCleanup: @Sendable (UInt64) -> Void
    private var coordinator: CloudGatewayTunnelHealthCoordinator
    private var nextGeneration: UInt64 = 0
    private var nextScheduleToken: UInt64 = 0
    private var activeGeneration: UInt64?
    private var latestPathRouteID: UInt64 = 0
    private var coordinatorWake: CloudGatewayTunnelHealthWake?
    private var scheduledWake: ScheduledWake?

    public init(
        runtime: any CloudGatewayTunnelHealthRuntimeAdapter,
        persistence: any CloudGatewayTunnelHealthPersistenceAdapter,
        notifications: any CloudGatewayTunnelHealthNotificationAdapter,
        scheduler: any CloudGatewayTunnelHealthScheduling = CloudGatewayTunnelHealthTaskScheduler(),
        timing: CloudGatewayTunnelHealthTiming = .production
    ) {
        let arbiter = CloudGatewayTunnelHealthEffectSubmissionArbiter()
        let intent = CloudGatewayTunnelHealthArtifactIntent()
        let artifactDriver = CloudGatewayTunnelHealthArtifactDriver(
            persistence: persistence,
            notifications: notifications,
            gate: arbiter,
            intent: intent,
            notificationRepairDeadline: timing.notificationOperationDeadline,
            now: { scheduler.now().monotonic }
        )
        self.runtime = runtime
        self.notifications = notifications
        self.scheduler = scheduler
        effectArbiter = arbiter
        artifactIntent = intent
        self.artifactDriver = artifactDriver
        coordinator = CloudGatewayTunnelHealthCoordinator(timing: timing)
        deadlineCleanup = { stoppingGeneration in
            Task { await artifactDriver.abandonStop(generation: stoppingGeneration) }
            intent.withCurrentState { state in
                guard state.generation != stoppingGeneration,
                      state.generation != nil else {
                    persistence.clear { _ in
                        await artifactDriver.requestCurrentRepair()
                    }
                    notifications.withdraw()
                    return
                }
                Task { await artifactDriver.requestCurrentRepair() }
            }
        }
    }

    public func start(tunnelIdentifier: String) async -> CloudGatewayTunnelHealthSession? {
        guard activeGeneration == nil else { return nil }
        artifactDriver.setDeadlineChangedHandler { [weak self] in
            await self?.artifactDeadlineChanged()
        }
        nextGeneration &+= 1
        let generation = nextGeneration
        activeGeneration = generation
        latestPathRouteID = 0
        let moment = scheduler.now()
        let transition = coordinator.start(
            session: CloudGatewayTunnelHealthSessionID(rawValue: generation),
            tunnelIdentifier: tunnelIdentifier,
            at: moment
        )
        artifactIntent.activate(
            generation: generation,
            desired: coordinator.desiredArtifacts
        )
        notifications.resumeRegistrations()
        effectArbiter.open(generation: generation)
        await artifactDriver.activate(
            generation: generation,
            desired: coordinator.desiredArtifacts
        )
        await apply(
            transition,
            generation: generation,
            at: moment.monotonic
        )
        return CloudGatewayTunnelHealthSession(generation: generation)
    }

    public func pathChanged(
        _ descriptor: CloudGatewayTunnelPathDescriptor,
        session: CloudGatewayTunnelHealthSession
    ) async {
        let generation = session.generation
        guard activeGeneration == generation,
              descriptor.routeID > latestPathRouteID else { return }
        latestPathRouteID = descriptor.routeID
        let moment = scheduler.now()
        let transition = coordinator.handle(
            .pathChanged(descriptor),
            at: moment
        )
        await apply(
            transition,
            generation: generation,
            at: moment.monotonic
        )
    }

    public nonisolated func prepareToStop() -> CloudGatewayTunnelHealthStopToken? {
        guard let generation = effectArbiter.closeCurrent(
            onClose: notifications.suspendRegistrations
        ) else { return nil }
        return makeStopToken(generation: generation)
    }

    public nonisolated func prepareToStop(
        session: CloudGatewayTunnelHealthSession
    ) -> CloudGatewayTunnelHealthStopToken? {
        guard effectArbiter.close(
            generation: session.generation,
            onClose: notifications.suspendRegistrations
        ) else { return nil }
        return makeStopToken(generation: session.generation)
    }

    private nonisolated func makeStopToken(
        generation: UInt64
    ) -> CloudGatewayTunnelHealthStopToken {
        return CloudGatewayTunnelHealthStopToken(
            generation: generation,
            effectArbiter: effectArbiter,
            cleanup: { self.deadlineCleanup(generation) }
        )
    }

    public func stop(
        _ token: CloudGatewayTunnelHealthStopToken,
        completion: @escaping @Sendable () -> Void
    ) async {
        await withCheckedContinuation { continuation in
            token.enqueueAfterSubmittedEffects { [self] in
                Task {
                    await finishStop(token, completion: completion)
                    continuation.resume()
                }
            }
        }
    }

    private func finishStop(
        _ token: CloudGatewayTunnelHealthStopToken,
        completion: @escaping @Sendable () -> Void
    ) async {
        guard activeGeneration == token.generation else {
            completion()
            return
        }
        scheduledWake?.cancellation.cancel()
        scheduledWake = nil
        coordinatorWake = nil
        activeGeneration = nil
        _ = coordinator.handle(.stop, at: scheduler.now())
        await artifactDriver.stop(
            generation: token.generation,
            completion: {
                token.disarmDeadlineCleanup()
                completion()
            }
        )
    }

    private func apply(
        _ transition: CloudGatewayTunnelHealthTransition,
        generation: UInt64,
        at now: Duration
    ) async {
        guard activeGeneration == generation else { return }
        coordinatorWake = transition.nextWake
        await artifactDriver.updateDesired(
            generation: generation,
            desired: coordinator.desiredArtifacts
        )
        await artifactDriver.advance(to: now)
        for effect in transition.effects {
            await execute(effect, generation: generation)
        }
        await scheduleNextWake(generation: generation)
    }

    private func scheduleNextWake(
        generation: UInt64
    ) async {
        guard activeGeneration == generation else { return }
        let artifactDeadline = await artifactDriver.nextNotificationRepairDeadline
        let deadline: Duration?
        switch (coordinatorWake?.deadline, artifactDeadline) {
        case let (left?, right?): deadline = min(left, right)
        case let (left?, nil): deadline = left
        case let (nil, right?): deadline = right
        case (nil, nil): deadline = nil
        }
        if scheduledWake?.deadline == deadline { return }
        scheduledWake?.cancellation.cancel()
        scheduledWake = nil
        guard let deadline else { return }
        nextScheduleToken &+= 1
        let token = nextScheduleToken
        let cancellation = scheduler.schedule(at: deadline) { [weak self] in
            await self?.receiveScheduledWake(token, generation: generation)
        }
        scheduledWake = ScheduledWake(
            token: token,
            deadline: deadline,
            cancellation: cancellation
        )
    }

    private func receiveScheduledWake(
        _ token: UInt64,
        generation: UInt64
    ) async {
        guard activeGeneration == generation,
              scheduledWake?.token == token else { return }
        scheduledWake = nil
        let moment = scheduler.now()
        if let wake = coordinatorWake,
           moment.monotonic >= wake.deadline {
            let transition = coordinator.handle(.wake(wake.id), at: moment)
            await apply(
                transition,
                generation: generation,
                at: moment.monotonic
            )
        } else {
            await artifactDriver.advance(to: moment.monotonic)
            await scheduleNextWake(generation: generation)
        }
    }

    private func artifactDeadlineChanged() async {
        guard let generation = activeGeneration else { return }
        await artifactDriver.advance(to: scheduler.now().monotonic)
        await scheduleNextWake(generation: generation)
    }

    private func receive(
        _ event: CloudGatewayTunnelHealthEvent,
        generation: UInt64
    ) async {
        guard activeGeneration == generation else { return }
        let moment = scheduler.now()
        let transition = coordinator.handle(event, at: moment)
        await apply(
            transition,
            generation: generation,
            at: moment.monotonic
        )
    }

    private func execute(
        _ effect: CloudGatewayTunnelHealthEffect,
        generation: UInt64
    ) async {
        let runtime = runtime
        switch effect {
        case let .readRuntime(id):
            effectArbiter.submit(generation: generation) { ticket in
                runtime.readRuntime { [weak self] stats in
                    ticket.drain()
                    await self?.receive(
                        .runtimeReadCompleted(id, stats),
                        generation: generation
                    )
                }
            }
        case let .refreshBinding(id):
            effectArbiter.submit(generation: generation) { ticket in
                runtime.refreshBinding { [weak self] result in
                    ticket.drain()
                    await self?.receive(
                        .recoveryCompleted(id, result),
                        generation: generation
                    )
                }
            }
        case let .restartBackend(id):
            guard runtime.backendRestartCapability == .supported else {
                effectArbiter.submit(generation: generation) { [weak self] ticket in
                    ticket.drain()
                    Task {
                        await self?.receive(
                            .recoveryCompleted(id, .unsupported),
                            generation: generation
                        )
                    }
                }
                return
            }
            effectArbiter.submit(generation: generation) { ticket in
                runtime.restartBackend { [weak self] result in
                    ticket.drain()
                    await self?.receive(
                        .recoveryCompleted(id, result),
                        generation: generation
                    )
                }
            }
        case .persist, .clearSnapshot, .registerNotification,
             .reconcileNotification, .withdrawNotification:
            await artifactDriver.execute(
                effect,
                generation: generation
            ) { [weak self] event in
                await self?.receive(event, generation: generation)
            }
        }
    }
}

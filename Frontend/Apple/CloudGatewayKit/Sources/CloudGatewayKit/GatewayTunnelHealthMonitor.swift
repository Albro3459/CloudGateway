import Foundation

public enum GatewayTunnelBackendRestartCapability: Equatable, Sendable {
    case supported
    case unsupported
}

public struct GatewayTunnelHealthSession: Hashable, Sendable {
    fileprivate let generation: UInt64

    fileprivate init(generation: UInt64) {
        self.generation = generation
    }
}

public protocol GatewayTunnelHealthRuntimeAdapter: Sendable {
    var backendRestartCapability: GatewayTunnelBackendRestartCapability { get }

    func readRuntime(
        completion: @escaping @Sendable (GatewayTunnelRuntimeStats?) async -> Void
    )

    func refreshBinding(
        completion: @escaping @Sendable (GatewayTunnelRecoveryResult) async -> Void
    )

    func restartBackend(
        completion: @escaping @Sendable (GatewayTunnelRecoveryResult) async -> Void
    )
}

public protocol GatewayTunnelHealthPersistenceAdapter: Sendable {
    func write(
        _ snapshot: GatewayTunnelHealthSnapshot,
        completion: @escaping @Sendable (GatewayTunnelEffectResult) async -> Void
    )

    func clear(
        completion: @escaping @Sendable (GatewayTunnelEffectResult) async -> Void
    )
}

public protocol GatewayTunnelHealthNotificationAdapter: Sendable {
    func register(
        completion: @escaping @Sendable (GatewayTunnelNotificationResult) async -> Void
    )

    func reconcile(
        completion: @escaping @Sendable (GatewayTunnelNotificationResult) async -> Void
    )

    func withdraw()
}

public protocol GatewayTunnelHealthWakeCancellation: Sendable {
    func cancel()
}

public protocol GatewayTunnelHealthScheduling: Sendable {
    func now() -> GatewayTunnelHealthMoment

    func schedule(
        at deadline: Duration,
        action: @escaping @Sendable () async -> Void
    ) -> any GatewayTunnelHealthWakeCancellation
}

public struct GatewayTunnelHealthStoreAdapter: GatewayTunnelHealthPersistenceAdapter {
    private let store: GatewayTunnelHealthStore

    public init(store: GatewayTunnelHealthStore) {
        self.store = store
    }

    public func write(
        _ snapshot: GatewayTunnelHealthSnapshot,
        completion: @escaping @Sendable (GatewayTunnelEffectResult) async -> Void
    ) {
        let result: GatewayTunnelEffectResult
        do {
            try store.write(snapshot)
            result = .success
        } catch {
            result = .failure
        }
        Task { await completion(result) }
    }

    public func clear(
        completion: @escaping @Sendable (GatewayTunnelEffectResult) async -> Void
    ) {
        let result: GatewayTunnelEffectResult
        do {
            try store.clear()
            result = .success
        } catch {
            result = .failure
        }
        Task { await completion(result) }
    }
}

public struct GatewayTunnelHealthTaskScheduler: GatewayTunnelHealthScheduling {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        origin = clock.now
    }

    public func now() -> GatewayTunnelHealthMoment {
        GatewayTunnelHealthMoment(
            monotonic: origin.duration(to: clock.now),
            wall: Date()
        )
    }

    public func schedule(
        at deadline: Duration,
        action: @escaping @Sendable () async -> Void
    ) -> any GatewayTunnelHealthWakeCancellation {
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
        return GatewayTunnelHealthTaskCancellation(task: task)
    }
}

private final class GatewayTunnelHealthTaskCancellation:
    GatewayTunnelHealthWakeCancellation,
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

public final class GatewayTunnelHealthEffectGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64?
    private var isOpen = false

    public init() {}

    func open(generation: UInt64) {
        lock.lock()
        self.generation = generation
        isOpen = true
        lock.unlock()
    }

    public func closeCurrent() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return nil }
        isOpen = false
        return generation
    }

    func close(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen, self.generation == generation else { return false }
        isOpen = false
        return true
    }

    @discardableResult
    func performIfOpen(
        generation: UInt64,
        _ action: () -> Void
    ) -> Bool {
        lock.lock()
        guard isOpen, self.generation == generation else {
            lock.unlock()
            return false
        }
        lock.unlock()
        action()
        return true
    }

    func isCurrentAndOpen(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpen && self.generation == generation
    }
}

public final class GatewayTunnelHealthStopToken: @unchecked Sendable {
    let generation: UInt64
    private let lock = NSLock()
    private var cleanup: (@Sendable () -> Void)?

    init(generation: UInt64, cleanup: @escaping @Sendable () -> Void) {
        self.generation = generation
        self.cleanup = cleanup
    }

    public func bestEffortDeadlineCleanup() {
        lock.lock()
        let cleanup = cleanup
        self.cleanup = nil
        lock.unlock()
        cleanup?()
    }

    public func disarmDeadlineCleanup() {
        lock.lock()
        cleanup = nil
        lock.unlock()
    }
}

public actor GatewayTunnelHealthMonitor {
    private struct ScheduledWake: Sendable {
        let token: UInt64
        let deadline: Duration
        let cancellation: any GatewayTunnelHealthWakeCancellation
    }

    private let runtime: any GatewayTunnelHealthRuntimeAdapter
    private let scheduler: any GatewayTunnelHealthScheduling
    private let artifactDriver: GatewayTunnelHealthArtifactDriver
    private nonisolated let effectGate: GatewayTunnelHealthEffectGate
    private nonisolated let artifactIntent: GatewayTunnelHealthArtifactIntent
    private nonisolated let deadlineCleanup: @Sendable (UInt64) -> Void
    private var coordinator: GatewayTunnelHealthCoordinator
    private var nextGeneration: UInt64 = 0
    private var nextScheduleToken: UInt64 = 0
    private var activeGeneration: UInt64?
    private var latestPathRouteID: UInt64 = 0
    private var coordinatorWake: GatewayTunnelHealthWake?
    private var scheduledWake: ScheduledWake?

    public init(
        runtime: any GatewayTunnelHealthRuntimeAdapter,
        persistence: any GatewayTunnelHealthPersistenceAdapter,
        notifications: any GatewayTunnelHealthNotificationAdapter,
        scheduler: any GatewayTunnelHealthScheduling = GatewayTunnelHealthTaskScheduler(),
        timing: GatewayTunnelHealthTiming = .production
    ) {
        let gate = GatewayTunnelHealthEffectGate()
        let intent = GatewayTunnelHealthArtifactIntent()
        let artifactDriver = GatewayTunnelHealthArtifactDriver(
            persistence: persistence,
            notifications: notifications,
            gate: gate,
            intent: intent,
            notificationRepairDeadline: timing.notificationOperationDeadline,
            now: { scheduler.now().monotonic }
        )
        self.runtime = runtime
        self.scheduler = scheduler
        effectGate = gate
        artifactIntent = intent
        self.artifactDriver = artifactDriver
        coordinator = GatewayTunnelHealthCoordinator(timing: timing)
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

    public func start(tunnelIdentifier: String) async -> GatewayTunnelHealthSession? {
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
            session: GatewayTunnelHealthSessionID(rawValue: generation),
            tunnelIdentifier: tunnelIdentifier,
            at: moment
        )
        artifactIntent.activate(
            generation: generation,
            desired: coordinator.desiredArtifacts
        )
        effectGate.open(generation: generation)
        await artifactDriver.activate(
            generation: generation,
            desired: coordinator.desiredArtifacts
        )
        await apply(
            transition,
            generation: generation,
            at: moment.monotonic
        )
        return GatewayTunnelHealthSession(generation: generation)
    }

    public func pathChanged(
        _ descriptor: GatewayTunnelPathDescriptor,
        session: GatewayTunnelHealthSession
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

    public nonisolated func prepareToStop() -> GatewayTunnelHealthStopToken? {
        guard let generation = effectGate.closeCurrent() else { return nil }
        return makeStopToken(generation: generation)
    }

    public nonisolated func prepareToStop(
        session: GatewayTunnelHealthSession
    ) -> GatewayTunnelHealthStopToken? {
        guard effectGate.close(generation: session.generation) else { return nil }
        return makeStopToken(generation: session.generation)
    }

    private nonisolated func makeStopToken(
        generation: UInt64
    ) -> GatewayTunnelHealthStopToken {
        return GatewayTunnelHealthStopToken(
            generation: generation,
            cleanup: { self.deadlineCleanup(generation) }
        )
    }

    public func stop(
        _ token: GatewayTunnelHealthStopToken,
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
        _ transition: GatewayTunnelHealthTransition,
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
        _ event: GatewayTunnelHealthEvent,
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
        _ effect: GatewayTunnelHealthEffect,
        generation: UInt64
    ) async {
        switch effect {
        case let .readRuntime(id):
            effectGate.performIfOpen(generation: generation) {
                runtime.readRuntime { [weak self] stats in
                    await self?.receive(
                        .runtimeReadCompleted(id, stats),
                        generation: generation
                    )
                }
            }
        case let .refreshBinding(id):
            effectGate.performIfOpen(generation: generation) {
                runtime.refreshBinding { [weak self] result in
                    await self?.receive(
                        .recoveryCompleted(id, result),
                        generation: generation
                    )
                }
            }
        case let .restartBackend(id):
            guard runtime.backendRestartCapability == .supported else {
                guard effectGate.performIfOpen(generation: generation, {}) else { return }
                await receive(
                    .recoveryCompleted(id, .unsupported),
                    generation: generation
                )
                return
            }
            effectGate.performIfOpen(generation: generation) {
                runtime.restartBackend { [weak self] result in
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

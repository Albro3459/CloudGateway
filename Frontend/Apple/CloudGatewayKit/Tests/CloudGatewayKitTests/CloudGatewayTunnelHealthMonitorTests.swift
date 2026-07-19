import Foundation
import Testing
@testable import CloudGatewayKit

private final class ManualHealthCancellation:
    CloudGatewayTunnelHealthWakeCancellation,
    @unchecked Sendable
{
    private let cancelAction: @Sendable () -> Void

    init(cancelAction: @escaping @Sendable () -> Void) {
        self.cancelAction = cancelAction
    }

    func cancel() {
        cancelAction()
    }
}

private final class ManualHealthScheduler:
    CloudGatewayTunnelHealthScheduling,
    @unchecked Sendable
{
    private struct Entry: Sendable {
        let id: UInt64
        let deadline: Duration
        let action: @Sendable () async -> Void
        var cancelled = false
        var fired = false
    }

    private let lock = NSLock()
    private let wallStart = Date(timeIntervalSince1970: 1_700_000_000)
    private var current: Duration = .zero
    private var nextID: UInt64 = 0
    private var entries: [UInt64: Entry] = [:]

    func now() -> CloudGatewayTunnelHealthMoment {
        lock.lock()
        let current = current
        lock.unlock()
        return CloudGatewayTunnelHealthMoment(
            monotonic: current,
            wall: wallStart.addingTimeInterval(current.gatewayTimeInterval)
        )
    }

    func schedule(
        at deadline: Duration,
        action: @escaping @Sendable () async -> Void
    ) -> any CloudGatewayTunnelHealthWakeCancellation {
        lock.lock()
        let id = nextID
        nextID &+= 1
        entries[id] = Entry(id: id, deadline: deadline, action: action)
        lock.unlock()
        return ManualHealthCancellation { [weak self] in
            self?.cancel(id: id)
        }
    }

    var activeCount: Int {
        lock.lock()
        let count = entries.values.filter { !$0.cancelled && !$0.fired }.count
        lock.unlock()
        return count
    }

    var latestID: UInt64? {
        lock.lock()
        let id = entries.keys.max()
        lock.unlock()
        return id
    }

    func fireNext(at seconds: Int) async throws {
        let entry = try takeNext(at: seconds)
        await entry.action()
    }

    func fireAgain(_ id: UInt64, at seconds: Int) async throws {
        let entry = try storedEntry(id: id, at: seconds)
        await entry.action()
    }

    private func takeNext(at seconds: Int) throws -> Entry {
        lock.lock()
        current = .seconds(seconds)
        let candidate = entries.values
            .filter { !$0.cancelled && !$0.fired && $0.deadline <= current }
            .min { left, right in
                left.deadline == right.deadline ? left.id < right.id : left.deadline < right.deadline
            }
        if var candidate {
            candidate.fired = true
            entries[candidate.id] = candidate
            lock.unlock()
            return candidate
        } else {
            lock.unlock()
            throw ManualSchedulerError.noDueWake
        }
    }

    private func storedEntry(id: UInt64, at seconds: Int) throws -> Entry {
        lock.lock()
        current = .seconds(seconds)
        let entry = entries[id]
        lock.unlock()
        guard let entry else { throw ManualSchedulerError.noDueWake }
        return entry
    }

    private func cancel(id: UInt64) {
        lock.lock()
        if var entry = entries[id] {
            entry.cancelled = true
            entries[id] = entry
        }
        lock.unlock()
    }

    private enum ManualSchedulerError: Error { case noDueWake }
}

private final class ControllableRuntimeAdapter:
    CloudGatewayTunnelHealthRuntimeAdapter,
    @unchecked Sendable
{
    typealias ReadCompletion = @Sendable (CloudGatewayTunnelRuntimeStats?) async -> Void
    typealias RecoveryCompletion = @Sendable (CloudGatewayTunnelRecoveryResult) async -> Void

    let backendRestartCapability: CloudGatewayTunnelBackendRestartCapability
    private let lock = NSLock()
    private var reads: [ReadCompletion] = []
    private var refreshes: [RecoveryCompletion] = []
    private var restarts: [RecoveryCompletion] = []

    init(capability: CloudGatewayTunnelBackendRestartCapability = .supported) {
        backendRestartCapability = capability
    }

    func readRuntime(completion: @escaping ReadCompletion) {
        lock.lock()
        reads.append(completion)
        lock.unlock()
    }

    func refreshBinding(completion: @escaping RecoveryCompletion) {
        lock.lock()
        refreshes.append(completion)
        lock.unlock()
    }

    func restartBackend(completion: @escaping RecoveryCompletion) {
        lock.lock()
        restarts.append(completion)
        lock.unlock()
    }

    var readCount: Int {
        lock.lock()
        let count = reads.count
        lock.unlock()
        return count
    }

    var refreshCount: Int {
        lock.lock()
        let count = refreshes.count
        lock.unlock()
        return count
    }

    var restartCount: Int {
        lock.lock()
        let count = restarts.count
        lock.unlock()
        return count
    }

    func completeRead(_ index: Int, stats: CloudGatewayTunnelRuntimeStats?) async throws {
        let completion = readCompletion(index)
        let required = try #require(completion)
        await required(stats)
    }

    func completeRefresh(
        _ index: Int,
        result: CloudGatewayTunnelRecoveryResult
    ) async throws {
        let completion = refreshCompletion(index)
        let required = try #require(completion)
        await required(result)
    }

    private func readCompletion(_ index: Int) -> ReadCompletion? {
        lock.lock()
        let completion = reads.indices.contains(index) ? reads[index] : nil
        lock.unlock()
        return completion
    }

    private func refreshCompletion(_ index: Int) -> RecoveryCompletion? {
        lock.lock()
        let completion = refreshes.indices.contains(index) ? refreshes[index] : nil
        lock.unlock()
        return completion
    }
}

private final class ControllablePersistenceAdapter:
    CloudGatewayTunnelHealthPersistenceAdapter,
    @unchecked Sendable
{
    enum Kind: Equatable, Sendable {
        case write(CloudGatewayTunnelHealthSnapshot)
        case clear
    }

    typealias Completion = @Sendable (CloudGatewayTunnelEffectResult) async -> Void
    private let lock = NSLock()
    private let writeSubmission: @Sendable () -> Void
    private let clearSubmission: @Sendable () -> Void
    private var storage: [(Kind, Completion)] = []

    init(
        writeSubmission: @escaping @Sendable () -> Void = {},
        clearSubmission: @escaping @Sendable () -> Void = {}
    ) {
        self.writeSubmission = writeSubmission
        self.clearSubmission = clearSubmission
    }

    func write(
        _ snapshot: CloudGatewayTunnelHealthSnapshot,
        completion: @escaping Completion
    ) {
        writeSubmission()
        lock.lock()
        storage.append((.write(snapshot), completion))
        lock.unlock()
    }

    func clear(completion: @escaping Completion) {
        clearSubmission()
        lock.lock()
        storage.append((.clear, completion))
        lock.unlock()
    }

    var calls: [Kind] {
        lock.lock()
        let calls = storage.map(\.0)
        lock.unlock()
        return calls
    }

    func complete(
        _ index: Int,
        result: CloudGatewayTunnelEffectResult = .success
    ) async throws {
        let completion = storedCompletion(index)
        let required = try #require(completion)
        await required(result)
    }

    private func storedCompletion(_ index: Int) -> Completion? {
        lock.lock()
        let completion = storage.indices.contains(index) ? storage[index].1 : nil
        lock.unlock()
        return completion
    }
}

private final class ControllableNotificationAdapter:
    CloudGatewayTunnelHealthNotificationAdapter,
    @unchecked Sendable
{
    enum Kind: Equatable, Sendable { case register, reconcile, withdraw }
    typealias Completion = @Sendable (CloudGatewayTunnelNotificationResult) async -> Void
    private let lock = NSLock()
    private let registerSubmission: @Sendable () -> Void
    private let reconcileSubmission: @Sendable () -> Void
    private let withdrawSubmission: @Sendable () -> Void
    private var storage: [(Kind, Completion?)] = []

    init(
        registerSubmission: @escaping @Sendable () -> Void = {},
        reconcileSubmission: @escaping @Sendable () -> Void = {},
        withdrawSubmission: @escaping @Sendable () -> Void = {}
    ) {
        self.registerSubmission = registerSubmission
        self.reconcileSubmission = reconcileSubmission
        self.withdrawSubmission = withdrawSubmission
    }

    func invalidateRegistrations() {}

    func register(completion: @escaping Completion) {
        registerSubmission()
        lock.lock()
        storage.append((.register, completion))
        lock.unlock()
    }

    func reconcile(completion: @escaping Completion) {
        reconcileSubmission()
        lock.lock()
        storage.append((.reconcile, completion))
        lock.unlock()
    }

    func withdraw() {
        withdrawSubmission()
        lock.lock()
        storage.append((.withdraw, nil))
        lock.unlock()
    }

    var calls: [Kind] {
        lock.lock()
        let calls = storage.map(\.0)
        lock.unlock()
        return calls
    }

    func complete(
        _ index: Int,
        result: CloudGatewayTunnelNotificationResult
    ) async throws {
        let completion = storedCompletion(index)
        let required = try #require(completion)
        await required(result)
    }

    private func storedCompletion(_ index: Int) -> Completion? {
        lock.lock()
        let completion = storage.indices.contains(index) ? storage[index].1 : nil
        lock.unlock()
        return completion
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

// Test twin of the production serial submission executor, injected so tests
// can wait on the arbiter's submission queue directly.
private final class SerialHealthSubmissionExecutor:
    CloudGatewayTunnelHealthEffectSubmissionExecuting,
    @unchecked Sendable
{
    private let queue = DispatchQueue(
        label: "com.gocloudlaunch.gateway.tests.effect-submission"
    )

    func enqueue(_ action: @escaping @Sendable () -> Void) {
        queue.async(execute: action)
    }

    func waitForPrecedingActions() {
        queue.sync {}
    }
}

private func makeMonitor(
    runtime: ControllableRuntimeAdapter = ControllableRuntimeAdapter(),
    persistence: ControllablePersistenceAdapter = ControllablePersistenceAdapter(),
    notifications: ControllableNotificationAdapter = ControllableNotificationAdapter(),
    scheduler: ManualHealthScheduler = ManualHealthScheduler()
) -> CloudGatewayTunnelHealthMonitor {
    CloudGatewayTunnelHealthMonitor(
        runtime: runtime,
        persistence: persistence,
        notifications: notifications,
        scheduler: scheduler
    )
}

@Test func monitorOwnsOneWakeAndIgnoresRefiredWake() async throws {
    let runtime = ControllableRuntimeAdapter()
    let scheduler = ManualHealthScheduler()
    let monitor = makeMonitor(runtime: runtime, scheduler: scheduler)

    let started = await monitor.start(tunnelIdentifier: "client-1")
    let session = try #require(started)
    await monitor.pathChanged(.init(isSatisfied: true, routeID: 1), session: session)
    #expect(scheduler.activeCount == 1)
    let firstWake = try #require(scheduler.latestID)

    try await scheduler.fireNext(at: 5)
    #expect(runtime.readCount == 1)
    #expect(scheduler.activeCount == 1)

    try await scheduler.fireAgain(firstWake, at: 6)
    #expect(runtime.readCount == 1)
    #expect(scheduler.activeCount == 1)
}

@Test func monitorMissingRuntimeCallbackKeepsWakingWithoutStartingMoreWork() async throws {
    let runtime = ControllableRuntimeAdapter()
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let scheduler = ManualHealthScheduler()
    let monitor = makeMonitor(
        runtime: runtime,
        persistence: persistence,
        notifications: notifications,
        scheduler: scheduler
    )

    let started = await monitor.start(tunnelIdentifier: "client-1")
    let session = try #require(started)
    await monitor.pathChanged(.init(isSatisfied: true, routeID: 1), session: session)
    for seconds in stride(from: 5, through: 30, by: 5) {
        try await scheduler.fireNext(at: seconds)
        #expect(scheduler.activeCount == 1)
    }

    #expect(runtime.readCount == 1)
    #expect(runtime.refreshCount == 0)
    #expect(runtime.restartCount == 0)
    #expect(notifications.calls.filter { $0 == .register }.count == 1)
    #expect(persistence.calls.contains { call in
        guard case let .write(snapshot) = call else { return false }
        return snapshot.health == .notPassingTraffic
    })
}

@Test func monitorIgnoresDuplicateRuntimeCompletion() async throws {
    let runtime = ControllableRuntimeAdapter()
    let persistence = ControllablePersistenceAdapter()
    let scheduler = ManualHealthScheduler()
    let monitor = makeMonitor(
        runtime: runtime,
        persistence: persistence,
        scheduler: scheduler
    )
    let started = await monitor.start(tunnelIdentifier: "client-1")
    let session = try #require(started)
    await monitor.pathChanged(.init(isSatisfied: true, routeID: 1), session: session)
    try await scheduler.fireNext(at: 5)

    let stats = CloudGatewayTunnelRuntimeStats(
        latestHandshakeEpochSeconds: 1_700_000_004,
        rxBytes: 10,
        txBytes: 10
    )
    try await runtime.completeRead(0, stats: stats)
    let callsAfterFirst = persistence.calls.count
    try await runtime.completeRead(0, stats: stats)
    #expect(persistence.calls.count == callsAfterFirst)

    try await scheduler.fireNext(at: 10)
    #expect(runtime.readCount == 2)
}

@Test func monitorClosedGatePreventsEffectsBeforeActorStop() async throws {
    let runtime = ControllableRuntimeAdapter()
    let scheduler = ManualHealthScheduler()
    let monitor = makeMonitor(runtime: runtime, scheduler: scheduler)
    let started = await monitor.start(tunnelIdentifier: "client-1")
    let session = try #require(started)
    await monitor.pathChanged(.init(isSatisfied: true, routeID: 1), session: session)

    let token = try #require(monitor.prepareToStop())
    try await scheduler.fireNext(at: 5)
    #expect(runtime.readCount == 0)

    await monitor.stop(token) {}
    #expect(scheduler.activeCount == 0)
}

@Test func failedInitialSnapshotClearRequestsRepair() async throws {
    let persistence = ControllablePersistenceAdapter()
    let monitor = makeMonitor(persistence: persistence)

    _ = await monitor.start(tunnelIdentifier: "client-1")
    #expect(persistence.calls == [.clear])

    try await persistence.complete(0, result: .failure)
    #expect(persistence.calls == [.clear, .clear])

    try await persistence.complete(1)
    #expect(persistence.calls == [.clear, .clear])
}

@Test func sessionQualifiedStopCannotCloseReplacementSession() async throws {
    let monitor = makeMonitor()
    let oldSession = try #require(
        await monitor.start(tunnelIdentifier: "client-1")
    )
    let oldToken = try #require(monitor.prepareToStop(session: oldSession))
    await monitor.stop(oldToken) {}

    let replacement = try #require(
        await monitor.start(tunnelIdentifier: "client-1")
    )
    #expect(monitor.prepareToStop(session: oldSession) == nil)
    let replacementToken = try #require(
        monitor.prepareToStop(session: replacement)
    )
    await monitor.stop(replacementToken) {}
}

@Test func monitorNormalStopDrainsOldArtifactAndFinalRepair() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let monitor = makeMonitor(
        persistence: persistence,
        notifications: notifications
    )
    let stopped = LockedFlag()

    _ = await monitor.start(tunnelIdentifier: "client-1")
    #expect(persistence.calls == [.clear])
    let token = try #require(monitor.prepareToStop())
    await monitor.stop(token) { stopped.set() }
    #expect(persistence.calls == [.clear, .clear])
    #expect(!stopped.value)

    try await persistence.complete(1)
    #expect(!stopped.value)
    try await persistence.complete(0)
    #expect(persistence.calls == [.clear, .clear, .clear])
    #expect(!stopped.value)
    try await persistence.complete(2)
    #expect(stopped.value)
    #expect(notifications.calls.filter { $0 == .withdraw }.count >= 2)
    let persistenceCallCount = persistence.calls.count
    let notificationCallCount = notifications.calls.count
    token.bestEffortDeadlineCleanup()
    #expect(persistence.calls.count == persistenceCallCount)
    #expect(notifications.calls.count == notificationCallCount)
}

@Test func stopDeadlineCleanupIsSynchronousAndIdempotent() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let monitor = makeMonitor(
        persistence: persistence,
        notifications: notifications
    )
    _ = await monitor.start(tunnelIdentifier: "client-1")
    let token = try #require(monitor.prepareToStop())

    token.bestEffortDeadlineCleanup()
    token.bestEffortDeadlineCleanup()
    #expect(persistence.calls.filter { $0 == .clear }.count >= 2)
    #expect(notifications.calls.filter { $0 == .withdraw }.count >= 2)
}

@Test func stopDeadlineCleanupClearsClosingOutageIntent() async throws {
    let runtime = ControllableRuntimeAdapter()
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let scheduler = ManualHealthScheduler()
    let monitor = makeMonitor(
        runtime: runtime,
        persistence: persistence,
        notifications: notifications,
        scheduler: scheduler
    )
    let started = await monitor.start(tunnelIdentifier: "client-1")
    let session = try #require(started)
    await monitor.pathChanged(.init(isSatisfied: true, routeID: 1), session: session)
    for seconds in stride(from: 5, through: 30, by: 5) {
        try await scheduler.fireNext(at: seconds)
    }
    #expect(notifications.calls.contains(.register))

    let token = try #require(monitor.prepareToStop())
    token.bestEffortDeadlineCleanup()

    #expect(persistence.calls.last == .clear)
    #expect(notifications.calls.last == .withdraw)
}

@Test func monitorRestartRejectsPriorSessionRuntimeCallback() async throws {
    let runtime = ControllableRuntimeAdapter()
    let scheduler = ManualHealthScheduler()
    let monitor = makeMonitor(runtime: runtime, scheduler: scheduler)
    let firstStart = await monitor.start(tunnelIdentifier: "client-1")
    let firstSession = try #require(firstStart)
    await monitor.pathChanged(
        .init(isSatisfied: true, routeID: 1),
        session: firstSession
    )
    try await scheduler.fireNext(at: 5)
    let oldToken = try #require(monitor.prepareToStop())
    await monitor.stop(oldToken) {}

    let secondStart = await monitor.start(tunnelIdentifier: "client-2")
    let secondSession = try #require(secondStart)
    await monitor.pathChanged(
        .init(isSatisfied: true, routeID: 2),
        session: secondSession
    )
    try await scheduler.fireNext(at: 10)
    #expect(runtime.readCount == 2)

    try await runtime.completeRead(
        0,
        stats: CloudGatewayTunnelRuntimeStats(
            latestHandshakeEpochSeconds: 1_700_000_010,
            rxBytes: 10,
            txBytes: 10
        )
    )
    try await scheduler.fireNext(at: 15)
    #expect(runtime.readCount == 2)
}

@Test func monitorRestartRejectsPriorSessionPathCallback() async throws {
    let runtime = ControllableRuntimeAdapter()
    let notifications = ControllableNotificationAdapter()
    let scheduler = ManualHealthScheduler()
    let monitor = makeMonitor(
        runtime: runtime,
        notifications: notifications,
        scheduler: scheduler
    )
    let firstStart = await monitor.start(tunnelIdentifier: "client-1")
    let firstSession = try #require(firstStart)
    let oldToken = try #require(monitor.prepareToStop())
    await monitor.stop(oldToken) {}

    let secondStart = await monitor.start(tunnelIdentifier: "client-2")
    _ = try #require(secondStart)
    await monitor.pathChanged(
        .init(isSatisfied: true, routeID: 99),
        session: firstSession
    )
    for seconds in [5, 10, 15, 20, 25, 30] {
        try await scheduler.fireNext(at: seconds)
    }

    #expect(runtime.readCount == 1)
    #expect(!notifications.calls.contains(.register))
}

@Test func artifactDriverRepairsOldWriteWithNewestSnapshot() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let old = CloudGatewayTunnelHealthSnapshot(
        tunnelIdentifier: "old",
        health: .unknown,
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    let newest = CloudGatewayTunnelHealthSnapshot(
        tunnelIdentifier: "new",
        health: .passingTraffic,
        updatedAt: Date(timeIntervalSince1970: 2)
    )
    let session1 = CloudGatewayTunnelHealthSessionID(rawValue: 1)
    let id = CloudGatewayTunnelHealthOperationID(session: session1, sequence: 1)

    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: old,
            notificationDesired: false,
            notificationRegistrationAllowed: true
        )
    )
    await driver.execute(.persist(id, old), generation: 1) { _ in }
    _ = gate.closeCurrent()
    gate.open(generation: 2)
    await driver.activate(
        generation: 2,
        desired: .init(
            snapshot: newest,
            notificationDesired: false,
            notificationRegistrationAllowed: true
        )
    )

    try await persistence.complete(0)
    #expect(persistence.calls.count == 2)
    #expect(persistence.calls[1] == .write(newest))
}

@Test func artifactDriverReconcilesOldNotificationAgainstNewestIntent() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let id = CloudGatewayTunnelHealthOperationID(
        session: CloudGatewayTunnelHealthSessionID(rawValue: 1),
        sequence: 1
    )

    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true,
            notificationOperationID: id
        )
    )
    await driver.execute(.registerNotification(id), generation: 1) { _ in }
    _ = gate.closeCurrent()
    gate.open(generation: 2)
    await driver.activate(
        generation: 2,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true
        )
    )

    try await notifications.complete(0, result: .registered)
    #expect(notifications.calls == [.register, .reconcile])
    try await notifications.complete(1, result: .absent)
    #expect(notifications.calls == [.register, .reconcile, .register])
}

@Test func artifactDriverWithdrawsOldNotificationForNewestHealthyIntent() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let id = CloudGatewayTunnelHealthOperationID(
        session: CloudGatewayTunnelHealthSessionID(rawValue: 1),
        sequence: 1
    )
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true,
            notificationOperationID: id
        )
    )
    await driver.execute(.registerNotification(id), generation: 1) { _ in }
    _ = gate.closeCurrent()
    gate.open(generation: 2)
    await driver.activate(
        generation: 2,
        desired: .init(
            snapshot: nil,
            notificationDesired: false,
            notificationRegistrationAllowed: true
        )
    )

    try await notifications.complete(0, result: .registered)
    #expect(notifications.calls == [.register, .withdraw])
}

@Test func notificationRepairReconciliationIsReservedUntilSubmitted() async throws {
    let executor = SerialHealthSubmissionExecutor()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter(executor: executor)
    let drained = LockedFlag()
    let drainWasDeferred = LockedFlag()
    let notifications = ControllableNotificationAdapter(
        reconcileSubmission: {
            guard let generation = gate.closeCurrent() else { return }
            gate.enqueueNormalStop(generation: generation) { drained.set() }
            if !drained.value { drainWasDeferred.set() }
        }
    )
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: ControllablePersistenceAdapter(),
        notifications: notifications,
        gate: gate
    )
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true
        )
    )

    await driver.requestCurrentRepair()
    executor.waitForPrecedingActions()

    #expect(drainWasDeferred.value)
    #expect(drained.value)
    #expect(notifications.calls == [.reconcile])
}

@Test func monitorRejectsOutOfOrderPathRouteID() async throws {
    let runtime = ControllableRuntimeAdapter()
    let notifications = ControllableNotificationAdapter()
    let scheduler = ManualHealthScheduler()
    let monitor = makeMonitor(
        runtime: runtime,
        notifications: notifications,
        scheduler: scheduler
    )
    let session = try #require(
        await monitor.start(tunnelIdentifier: "client-1")
    )

    await monitor.pathChanged(
        .init(isSatisfied: false, routeID: 2),
        session: session
    )
    await monitor.pathChanged(
        .init(isSatisfied: true, routeID: 1),
        session: session
    )
    for seconds in stride(from: 5, through: 30, by: 5) {
        try await scheduler.fireNext(at: seconds)
    }

    #expect(runtime.readCount == 1)
    #expect(!notifications.calls.contains(.register))
}

@Test func lostNotificationRepairDoesNotBlockNewestSnapshotRepair() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let first = CloudGatewayTunnelHealthSnapshot(
        tunnelIdentifier: "new",
        health: .unknown,
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    let newest = CloudGatewayTunnelHealthSnapshot(
        tunnelIdentifier: "new",
        health: .passingTraffic,
        updatedAt: Date(timeIntervalSince1970: 2)
    )
    let oldID = CloudGatewayTunnelHealthOperationID(
        session: CloudGatewayTunnelHealthSessionID(rawValue: 1),
        sequence: 1
    )

    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true,
            notificationOperationID: oldID
        )
    )
    await driver.execute(.registerNotification(oldID), generation: 1) { _ in }
    _ = gate.closeCurrent()
    gate.open(generation: 2)
    await driver.activate(
        generation: 2,
        desired: .init(
            snapshot: first,
            notificationDesired: true,
            notificationRegistrationAllowed: true
        )
    )

    try await notifications.complete(0, result: .registered)
    #expect(persistence.calls == [.write(first)])
    #expect(notifications.calls == [.register, .reconcile])
    await driver.updateDesired(
        generation: 2,
        desired: .init(
            snapshot: newest,
            notificationDesired: true,
            notificationRegistrationAllowed: true
        )
    )
    try await persistence.complete(0)
    #expect(persistence.calls == [.write(first), .write(newest)])
}

@Test func notificationRepairWaitsForCurrentRegistration() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let old = CloudGatewayTunnelHealthSnapshot(
        tunnelIdentifier: "old",
        health: .unknown,
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    let oldID = CloudGatewayTunnelHealthOperationID(
        session: CloudGatewayTunnelHealthSessionID(rawValue: 1),
        sequence: 1
    )
    let currentID = CloudGatewayTunnelHealthOperationID(
        session: CloudGatewayTunnelHealthSessionID(rawValue: 2),
        sequence: 1
    )

    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: old,
            notificationDesired: false,
            notificationRegistrationAllowed: true
        )
    )
    await driver.execute(.persist(oldID, old), generation: 1) { _ in }
    _ = gate.closeCurrent()
    gate.open(generation: 2)
    await driver.activate(
        generation: 2,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true,
            notificationOperationID: currentID
        )
    )
    await driver.execute(.registerNotification(currentID), generation: 2) { _ in }

    try await persistence.complete(0)
    #expect(notifications.calls == [.register])
    try await notifications.complete(0, result: .registered)
    #expect(notifications.calls == [.register, .reconcile])
}

@Test func deferredNotificationIsCancelledWhenHealthRecovers() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let session = CloudGatewayTunnelHealthSessionID(rawValue: 1)
    let first = CloudGatewayTunnelHealthOperationID(session: session, sequence: 1)
    let second = CloudGatewayTunnelHealthOperationID(session: session, sequence: 2)
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true,
            notificationOperationID: first
        )
    )
    await driver.execute(.registerNotification(first), generation: 1) { _ in }
    await driver.updateDesired(
        generation: 1,
        desired: .empty
    )
    await driver.execute(.withdrawNotification, generation: 1) { _ in }
    await driver.updateDesired(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true,
            notificationOperationID: second
        )
    )
    await driver.execute(.registerNotification(second), generation: 1) { _ in }
    await driver.updateDesired(generation: 1, desired: .empty)
    await driver.execute(.withdrawNotification, generation: 1) { _ in }

    try await notifications.complete(0, result: .registered)
    #expect(notifications.calls.filter { $0 == .register }.count == 1)
}

@Test func olderRegisteredNotificationSupersedesDeferredStableIDAdd() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let session = CloudGatewayTunnelHealthSessionID(rawValue: 1)
    let first = CloudGatewayTunnelHealthOperationID(session: session, sequence: 1)
    let second = CloudGatewayTunnelHealthOperationID(session: session, sequence: 2)
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true,
            notificationOperationID: first
        )
    )
    await driver.execute(.registerNotification(first), generation: 1) { _ in
        await driver.updateDesired(
            generation: 1,
            desired: .init(
                snapshot: nil,
                notificationDesired: true,
                notificationRegistrationAllowed: true
            )
        )
    }
    await driver.updateDesired(generation: 1, desired: .empty)
    await driver.execute(.withdrawNotification, generation: 1) { _ in }
    await driver.updateDesired(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true,
            notificationOperationID: second
        )
    )
    await driver.execute(.registerNotification(second), generation: 1) { _ in }

    try await notifications.complete(0, result: .registered)
    #expect(notifications.calls.filter { $0 == .register }.count == 1)
}

@Test func notificationRepairDoesNotRegisterAfterRecovery() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true
        )
    )
    await driver.requestCurrentRepair()
    #expect(notifications.calls == [.reconcile])

    await driver.updateDesired(generation: 1, desired: .empty)
    try await notifications.complete(0, result: .absent)

    #expect(!notifications.calls.contains(.register))
    #expect(notifications.calls.last == .withdraw)
}

@Test func successfulRepairAddSatisfiesDeferredCoordinatorRegistration() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let id = CloudGatewayTunnelHealthOperationID(
        session: CloudGatewayTunnelHealthSessionID(rawValue: 1),
        sequence: 1
    )
    let completed = LockedFlag()
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true
        )
    )
    await driver.requestCurrentRepair()
    try await notifications.complete(0, result: .absent)
    #expect(notifications.calls == [.reconcile, .register])

    await driver.updateDesired(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true,
            notificationOperationID: id
        )
    )
    await driver.execute(.registerNotification(id), generation: 1) { event in
        guard event == .notificationCompleted(id, .registered) else { return }
        completed.set()
        await driver.updateDesired(
            generation: 1,
            desired: .init(
                snapshot: nil,
                notificationDesired: true,
                notificationRegistrationAllowed: true
            )
        )
    }
    try await notifications.complete(1, result: .registered)

    #expect(completed.value)
    #expect(notifications.calls.filter { $0 == .register }.count == 1)
}

@Test func missingRepairReconciliationYieldsToCurrentRegistration() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let id = CloudGatewayTunnelHealthOperationID(
        session: CloudGatewayTunnelHealthSessionID(rawValue: 1),
        sequence: 1
    )
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true
        )
    )
    await driver.requestCurrentRepair()
    await driver.advance(to: .zero)
    await driver.updateDesired(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true,
            notificationOperationID: id
        )
    )
    await driver.execute(.registerNotification(id), generation: 1) { _ in }
    #expect(notifications.calls == [.reconcile])

    await driver.advance(to: .seconds(10))
    #expect(notifications.calls == [.reconcile, .register])
}

@Test func missingRepairRegistrationYieldsToCurrentReconciliation() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let id = CloudGatewayTunnelHealthOperationID(
        session: CloudGatewayTunnelHealthSessionID(rawValue: 1),
        sequence: 1
    )
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true
        )
    )
    await driver.requestCurrentRepair()
    try await notifications.complete(0, result: .absent)
    await driver.advance(to: .zero)
    await driver.updateDesired(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true,
            notificationOperationID: id
        )
    )
    await driver.execute(.registerNotification(id), generation: 1) { _ in }
    #expect(notifications.calls == [.reconcile, .register])

    await driver.advance(to: .seconds(10))
    #expect(notifications.calls == [.reconcile, .register, .reconcile])
}

@Test func newerCoordinatorNotificationSupersedesMissingCallback() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let session = CloudGatewayTunnelHealthSessionID(rawValue: 1)
    let first = CloudGatewayTunnelHealthOperationID(session: session, sequence: 1)
    let stopped = LockedFlag()
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true,
            notificationOperationID: first
        )
    )
    await driver.execute(.registerNotification(first), generation: 1) { _ in }
    for sequence in 2...5 {
        let next = CloudGatewayTunnelHealthOperationID(
            session: session,
            sequence: UInt64(sequence)
        )
        await driver.updateDesired(
            generation: 1,
            desired: .init(
                snapshot: nil,
                notificationDesired: true,
                notificationRegistrationAllowed: true,
                notificationOperationID: next
            )
        )
        await driver.execute(.reconcileNotification(next), generation: 1) { _ in }
    }

    let pendingCount = await driver.pendingNotificationOperationCount
    #expect(pendingCount == 1)
    try await notifications.complete(4, result: .registered)
    _ = gate.closeCurrent()
    await driver.stop(generation: 1) { stopped.set() }
    try await persistence.complete(0)
    #expect(!stopped.value)

    try await notifications.complete(0, result: .registered)
    #expect(notifications.calls.last == .withdraw)
    try await persistence.complete(1)
    #expect(stopped.value)
}

@Test func failedSnapshotRepairRemainsDueAndBlocksNormalStop() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let stopped = LockedFlag()
    gate.open(generation: 1)
    await driver.activate(generation: 1, desired: .empty)
    _ = gate.closeCurrent()
    await driver.stop(generation: 1) { stopped.set() }

    try await persistence.complete(0, result: .failure)
    #expect(!stopped.value)
    await driver.requestCurrentRepair()
    #expect(persistence.calls == [.clear, .clear])
    try await persistence.complete(1)
    #expect(stopped.value)
}

@Test func failedNotificationRepairRemainsDueForLaterRetry() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let id = CloudGatewayTunnelHealthOperationID(
        session: CloudGatewayTunnelHealthSessionID(rawValue: 1),
        sequence: 1
    )
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true,
            notificationOperationID: id
        )
    )
    await driver.execute(.registerNotification(id), generation: 1) { _ in }
    _ = gate.closeCurrent()
    gate.open(generation: 2)
    await driver.activate(
        generation: 2,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true,
            notificationOperationID: id
        )
    )
    try await notifications.complete(0, result: .registered)
    try await notifications.complete(1, result: .retryableFailure)

    await driver.requestCurrentRepair()
    #expect(notifications.calls == [.register, .reconcile, .reconcile])
}

@Test func artifactDriverStopWaitsForPendingNotificationAndRepair() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let stopped = LockedFlag()
    let id = CloudGatewayTunnelHealthOperationID(
        session: CloudGatewayTunnelHealthSessionID(rawValue: 1),
        sequence: 1
    )
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true,
            notificationOperationID: id
        )
    )
    await driver.execute(.registerNotification(id), generation: 1) { _ in }
    _ = gate.closeCurrent()
    await driver.stop(generation: 1) { stopped.set() }
    #expect(!stopped.value)

    try await persistence.complete(0)
    #expect(!stopped.value)
    try await notifications.complete(0, result: .registered)
    #expect(persistence.calls == [.clear, .clear])
    #expect(!stopped.value)
    try await persistence.complete(1)
    #expect(stopped.value)
}

@Test func artifactDriverStopWaitsForPhysicalRepairRegistration() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let stopped = LockedFlag()
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true
        )
    )
    await driver.requestCurrentRepair()
    try await notifications.complete(0, result: .absent)
    #expect(notifications.calls == [.reconcile, .register])

    _ = gate.closeCurrent()
    await driver.stop(generation: 1) { stopped.set() }
    try await persistence.complete(0)
    try await persistence.complete(1)
    #expect(!stopped.value)

    try await notifications.complete(1, result: .registered)
    #expect(notifications.calls.last == .withdraw)
    #expect(stopped.value)
}

@Test func artifactDriverStopDrainsAfterPhysicalRepairRegistrationFailure() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let stopped = LockedFlag()
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true
        )
    )
    await driver.requestCurrentRepair()
    try await notifications.complete(0, result: .absent)
    #expect(notifications.calls == [.reconcile, .register])

    _ = gate.closeCurrent()
    await driver.stop(generation: 1) { stopped.set() }
    try await persistence.complete(0)
    try await persistence.complete(1)
    #expect(!stopped.value)

    try await notifications.complete(1, result: .retryableFailure)
    #expect(notifications.calls.last == .withdraw)
    #expect(stopped.value)
}

@Test func artifactDriverBoundsLostPhysicalRegistrationBookkeeping() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let stopped = LockedFlag()
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true
        )
    )
    await driver.requestCurrentRepair()
    try await notifications.complete(0, result: .absent)

    await driver.advance(to: .seconds(10))
    try await notifications.complete(2, result: .absent)
    await driver.advance(to: .seconds(20))
    try await notifications.complete(4, result: .absent)
    #expect(await driver.physicalNotificationRegistrationGenerationCount == 1)

    _ = gate.closeCurrent()
    await driver.stop(generation: 1) { stopped.set() }
    await driver.abandonStop(generation: 1)
    #expect(await driver.physicalNotificationRegistrationGenerationCount == 0)
    #expect(!stopped.value)
}

@Test func artifactDriverAbandonmentUnblocksReplacementNotificationLane() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let first = CloudGatewayTunnelHealthOperationID(
        session: CloudGatewayTunnelHealthSessionID(rawValue: 1),
        sequence: 1
    )
    let replacement = CloudGatewayTunnelHealthOperationID(
        session: CloudGatewayTunnelHealthSessionID(rawValue: 2),
        sequence: 1
    )
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true,
            notificationOperationID: first
        )
    )
    await driver.execute(.registerNotification(first), generation: 1) { _ in }
    _ = gate.closeCurrent()
    await driver.stop(generation: 1) {}

    await driver.abandonStop(generation: 1)
    gate.open(generation: 2)
    await driver.activate(
        generation: 2,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true,
            notificationOperationID: replacement
        )
    )
    await driver.execute(.registerNotification(replacement), generation: 2) { _ in }
    #expect(notifications.calls == [.register, .withdraw, .register])

    try await notifications.complete(0, result: .registered)
    try await notifications.complete(2, result: .registered)
    #expect(notifications.calls.last == .reconcile)
}

@Test func artifactDriverAbandonmentRetiresPendingNotificationReconciliation() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true
        )
    )
    await driver.requestCurrentRepair()
    #expect(notifications.calls == [.reconcile])

    _ = gate.closeCurrent()
    await driver.abandonStop(generation: 1)
    try await notifications.complete(0, result: .absent)

    #expect(notifications.calls == [.reconcile, .withdraw])
}

@Test func artifactDriverAbandonmentRepairsLatePersistenceTowardEmptyIntent() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let snapshot = CloudGatewayTunnelHealthSnapshot(
        tunnelIdentifier: "client-1",
        health: .notPassingTraffic,
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    let id = CloudGatewayTunnelHealthOperationID(
        session: CloudGatewayTunnelHealthSessionID(rawValue: 1),
        sequence: 1
    )
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: snapshot,
            notificationDesired: false,
            notificationRegistrationAllowed: true
        )
    )
    await driver.execute(.persist(id, snapshot), generation: 1) { _ in }

    _ = gate.closeCurrent()
    await driver.abandonStop(generation: 1)
    try await persistence.complete(0)

    #expect(persistence.calls == [.write(snapshot), .clear])
}

@Test func artifactDriverAbandonmentRepairsInFlightSnapshotWriteAfterDeadlineClear() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    let snapshot = CloudGatewayTunnelHealthSnapshot(
        tunnelIdentifier: "client-1",
        health: .notPassingTraffic,
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: snapshot,
            notificationDesired: false,
            notificationRegistrationAllowed: true
        )
    )
    await driver.requestCurrentRepair()
    #expect(persistence.calls == [.write(snapshot)])

    _ = gate.closeCurrent()
    await driver.abandonStop(generation: 1)
    persistence.clear { _ in }
    try await persistence.complete(1)
    try await persistence.complete(0)

    #expect(persistence.calls == [.write(snapshot), .clear, .clear])
}

@Test func artifactDriverAbandonmentRepairsInFlightNotificationRegistration() async throws {
    let persistence = ControllablePersistenceAdapter()
    let notifications = ControllableNotificationAdapter()
    let gate = CloudGatewayTunnelHealthEffectSubmissionArbiter()
    let driver = CloudGatewayTunnelHealthArtifactDriver(
        persistence: persistence,
        notifications: notifications,
        gate: gate
    )
    gate.open(generation: 1)
    await driver.activate(
        generation: 1,
        desired: .init(
            snapshot: nil,
            notificationDesired: true,
            notificationRegistrationAllowed: true
        )
    )
    await driver.requestCurrentRepair()
    try await notifications.complete(0, result: .absent)
    #expect(notifications.calls == [.reconcile, .register])

    _ = gate.closeCurrent()
    await driver.abandonStop(generation: 1)
    notifications.withdraw()
    try await notifications.complete(1, result: .registered)

    #expect(notifications.calls == [.reconcile, .register, .withdraw, .withdraw])
}

@Test func unsupportedBackendRestartConfirmsWithoutCallingAdapter() async throws {
    let runtime = ControllableRuntimeAdapter(capability: .unsupported)
    let notifications = ControllableNotificationAdapter()
    let scheduler = ManualHealthScheduler()
    let monitor = makeMonitor(
        runtime: runtime,
        notifications: notifications,
        scheduler: scheduler
    )
    let started = await monitor.start(tunnelIdentifier: "client-1")
    let session = try #require(started)
    await monitor.pathChanged(.init(isSatisfied: true, routeID: 1), session: session)

    var completedReads = 0
    var completedRefreshes = 0
    for seconds in stride(from: 5, through: 45, by: 5) {
        try await scheduler.fireNext(at: seconds)
        while completedReads < runtime.readCount {
            try await runtime.completeRead(
                completedReads,
                stats: CloudGatewayTunnelRuntimeStats(
                    latestHandshakeEpochSeconds: 0,
                    rxBytes: 0,
                    txBytes: UInt64(seconds) * 1_000
                )
            )
            completedReads += 1
        }
        while completedRefreshes < runtime.refreshCount {
            try await runtime.completeRefresh(completedRefreshes, result: .accepted)
            completedRefreshes += 1
        }
    }

    #expect(runtime.refreshCount == 1)
    #expect(runtime.restartCount == 0)
    #expect(notifications.calls.filter { $0 == .register }.count == 1)
}
